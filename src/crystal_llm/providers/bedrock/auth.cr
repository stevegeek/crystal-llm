# ported from lib/ruby_llm/providers/bedrock/auth.rb @ ruby_llm 1.15.0
#
# AWS SigV4 request signing for Bedrock — now LIVE.
#
# ruby_llm signs every Bedrock request: it overrides `sync_response`/`list_models` to
# call `signed_post`/`signed_get`, which compute SigV4 headers via a hand-rolled
# `sign_headers` (Digest::SHA256 + OpenSSL::HMAC over the AWS canonical request).
#
# The Crystal port threads signing through a single provider hook —
# `Provider#sign_headers(method, url, body)` (default `{}`), merged into requests by
# the frozen sync/stream/list pipeline (provider_completion.cr + streaming.cr). Bedrock
# OVERRIDES that hook here to compute SigV4 with the `awscr-signer` shard rather than
# re-deriving the canonical-request math: we build an `HTTP::Request` mirroring the
# outgoing crest call, set its `Host` to the target host, sign it, and lift the
# `Authorization`/`X-Amz-Date`/`X-Amz-Content-Sha256` (+ `X-Amz-Security-Token`) headers
# back out to merge onto the real request.
#
# Divergences from ruby_llm's auth.rb:
# - The canonical-request construction (canonical_uri/canonical_query_string/uri_encode/
#   signing_key) is delegated to awscr-signer's `Signers::V4`, so those private helpers
#   are gone. awscr-signer's `V4::Request` percent-encodes the path the same way (it
#   refuses query params on the path and wants them on `#query`; the only signed Bedrock
#   GET — /foundation-models — carries none, so this never bites).
# - `@config.bedrock_session_token` -> passed to `V4.new`'s `amz_security_token:`, which
#   adds the `X-Amz-Security-Token` header before signing (so it's part of SignedHeaders,
#   matching ruby_llm). No manual token header is needed.
# - Service name: ruby_llm always signs with service "bedrock" (both runtime + control
#   plane). We keep that to stay byte-for-byte compatible with ruby_llm's signature.
# - The `Host` header is set explicitly to the URL's host so it is part of the canonical
#   request's SignedHeaders (awscr-signer signs whatever headers are present; AWS rejects
#   a SigV4 request whose `host` isn't signed). It matches the crest target host.
require "json"
require "http/request"
require "awscr-signer"
require "../bedrock"

module CrystalLLM
  module Providers
    class Bedrock < Provider
      # Computes the SigV4 `Authorization` (+ X-Amz-*) headers for a request and returns
      # them as a plain Hash to merge onto the outgoing crest request. `url` may be a
      # path (resolved against `api_base`) or a full URL (the control-plane models host);
      # the signed `Host` is derived from whichever host the request actually targets.
      def sign_headers(method : String, url : String, body : String) : Hash(String, String)
        target = signing_target(url)
        host = URI.parse(target).host || ""

        request = HTTP::Request.new(method.upcase, signing_resource(target), body: body)
        # Sign `host` so it lands in SignedHeaders (AWS requires it). Matches the crest
        # target host — crest derives Host from the request URL, which is the same host.
        request.headers["Host"] = host

        signer = Awscr::Signer::Signers::V4.new(
          service: bedrock_signing_service,
          region: @config.bedrock_region || "",
          aws_access_key: @config.bedrock_api_key || "",
          aws_secret_key: @config.bedrock_secret_key || "",
          amz_security_token: @config.bedrock_session_token
        )
        # Mutates `request.headers`, adding X-Amz-Date, X-Amz-Content-Sha256,
        # Authorization (+ X-Amz-Security-Token when a session token was given).
        signer.sign(request)

        signed = {
          "Authorization" => request.headers["Authorization"],
          "X-Amz-Date"    => request.headers["X-Amz-Date"],
          "Content-Type"  => "application/json",
        } of String => String

        if sha = request.headers["X-Amz-Content-Sha256"]?
          signed["X-Amz-Content-Sha256"] = sha
        end
        if token = request.headers["X-Amz-Security-Token"]?
          signed["X-Amz-Security-Token"] = token
        end

        signed
      end

      # ruby_llm signs Bedrock with the "bedrock" service for both planes.
      private def bedrock_signing_service : String
        "bedrock"
      end

      # Resolves `url` (a path or a full URL) to the full URL whose host we sign against.
      # A path is taken to target the runtime `api_base`; a full URL (the control-plane
      # models endpoint) is used as-is.
      private def signing_target(url : String) : String
        return url if url.starts_with?("http://") || url.starts_with?("https://")
        "#{api_base.chomp('/')}/#{url.lchop('/')}"
      end

      # The path+query portion awscr-signer signs (it derives the canonical path itself).
      private def signing_resource(target : String) : String
        uri = URI.parse(target)
        path = uri.path
        path = "/" if path.nil? || path.empty?
        query = uri.query
        query && !query.empty? ? "#{path}?#{query}" : path
      end
    end
  end
end
