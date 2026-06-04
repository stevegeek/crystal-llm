# ported from lib/ruby_llm/providers/bedrock/auth.rb @ ruby_llm 1.15.0
#
# AWS SigV4 request signing for Bedrock.
#
# AUTH DEFERRED (best-effort port): ruby_llm signs every Bedrock request — it overrides
# `sync_response`/`list_models` to call `signed_post`/`signed_get`, which compute SigV4
# headers via `sign_headers`. The Crystal port does NOT yet thread per-request signing
# through the Connection layer (the frozen `sync_response`/`list_models` POST/GET with
# the static `headers` hash). So:
#   * `headers` (bedrock.cr) is a best-effort stub — see its note.
#   * `sign_headers` below is a faithful, self-contained SigV4 v4 computation, ready to
#     be wired into Connection. It is pure (given method/path/body/timestamp) and is
#     unit-testable, but is NOT yet invoked by the request pipeline.
# This is the documented HARD-AUTH deferral. No live calls are made; the unit surface
# (render_payload/parse_completion_response/build_chunk) is unaffected.
#
# Divergences from ruby_llm's auth.rb:
# - `Digest::SHA256.hexdigest` -> `Digest::SHA256.hexdigest` (Crystal stdlib, same name).
# - `OpenSSL::HMAC.hexdigest('sha256', ...)` -> `OpenSSL::HMAC.hexdigest(:sha256, ...)`.
# - `OpenSSL::HMAC.digest('sha256', ...)` (raw bytes) -> `OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, ...)`.
# - `Time.now.utc.strftime` -> `Time.utc.to_s(format)`.
# - URI percent-encoding uses `URI.encode_path_segment`/manual encode (Crystal has no
#   `URI.encode_www_form_component` with identical semantics); the canonicalization is
#   approximated and clearly marked, since it is not yet on a live path.
require "json"
require "digest/sha256"
require "openssl"
require "openssl/hmac"
require "../bedrock"

module CrystalLLM
  module Providers
    class Bedrock < Provider
      # Computes the SigV4 `Authorization` (+ x-amz-*) headers for a request.
      # `now` is injectable for deterministic testing (defaults to Time.utc).
      def sign_headers(method : String, path : String, body : String,
                       base_url : String = api_base, now : Time = Time.utc) : Hash(String, String)
        amz_date = now.to_s("%Y%m%dT%H%M%SZ")
        date_stamp = now.to_s("%Y%m%d")

        uri = URI.parse(path)
        canonical_uri = canonical_uri(uri.path)
        canonical_query = canonical_query_string(uri.query)
        payload_hash = Digest::SHA256.hexdigest(body)

        host = URI.parse(base_url).host || ""
        headers = {
          "host"                 => host,
          "x-amz-content-sha256" => payload_hash,
          "x-amz-date"           => amz_date,
        }
        if token = @config.bedrock_session_token
          headers["x-amz-security-token"] = token
        end

        sorted_keys = headers.keys.sort!
        signed_headers = sorted_keys.join(";")
        canonical_headers = sorted_keys.map { |key| "#{key}:#{headers[key].strip}\n" }.join

        canonical_request = [
          method,
          canonical_uri,
          canonical_query,
          canonical_headers,
          signed_headers,
          payload_hash,
        ].join("\n")

        region = @config.bedrock_region
        credential_scope = "#{date_stamp}/#{region}/bedrock/aws4_request"
        string_to_sign = [
          "AWS4-HMAC-SHA256",
          amz_date,
          credential_scope,
          Digest::SHA256.hexdigest(canonical_request),
        ].join("\n")

        signature = OpenSSL::HMAC.hexdigest(:sha256, signing_key(date_stamp), string_to_sign)

        result = {
          "X-Amz-Date"           => amz_date,
          "X-Amz-Content-Sha256" => payload_hash,
          "Authorization"        => "AWS4-HMAC-SHA256 Credential=#{@config.bedrock_api_key}/#{credential_scope}, " \
                             "SignedHeaders=#{signed_headers}, Signature=#{signature}",
          "Content-Type" => "application/json",
        }
        if token = @config.bedrock_session_token
          result["X-Amz-Security-Token"] = token
        end
        result
      end

      private def canonical_query_string(raw_query : String?) : String
        return "" if raw_query.nil? || raw_query.empty?

        params = URI::Params.parse(raw_query)
        pairs = [] of Tuple(String, String)
        params.each { |key, value| pairs << {key, value} }
        pairs.sort_by!(&.first)
        pairs.map { |key, value| "#{uri_encode(key)}=#{uri_encode(value)}" }.join("&")
      end

      private def canonical_uri(path : String?) : String
        return "/" if path.nil? || path.empty?

        segments = path.split("/", -1).map { |segment| uri_encode(segment) }
        canonical = segments.join("/")
        canonical.starts_with?("/") ? canonical : "/#{canonical}"
      end

      # Approximation of ruby_llm's `URI.encode_www_form_component(...).gsub('+','%20')`.
      private def uri_encode(text : String) : String
        URI.encode_www_form(text).gsub("+", "%20").gsub("%7E", "~")
      end

      private def signing_key(date_stamp : String) : Bytes
        k_date = hmac("AWS4#{@config.bedrock_secret_key}".to_slice, date_stamp.to_slice)
        k_region = hmac(k_date, (@config.bedrock_region || "").to_slice)
        k_service = hmac(k_region, "bedrock".to_slice)
        hmac(k_service, "aws4_request".to_slice)
      end

      private def hmac(key : Bytes, data : Bytes) : Bytes
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, data)
      end
    end
  end
end
