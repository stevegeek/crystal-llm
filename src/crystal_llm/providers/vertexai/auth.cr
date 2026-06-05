# ported from lib/ruby_llm/providers/vertexai.rb (auth path) @ ruby_llm 1.15.0
#
# Google service-account -> OAuth2 access-token minting for Vertex AI.
#
# ruby_llm delegates this to the `googleauth` gem: a service-account key produces a
# `Google::Auth::ServiceAccountCredentials`, which under the hood builds a signed JWT
# assertion (RS256, signed with the key's private_key), exchanges it at the Google
# OAuth2 token endpoint for a bearer access_token (the jwt-bearer grant), and caches
# that token until it expires. `headers` then emits `Authorization: Bearer <token>`.
#
# This file ports that *service-account-key* path directly (the priority per the parity
# audit), using the `jwt` shard (RS256 via OpenSSL) to build/sign the assertion and
# `crest` for the token exchange. The minted token is memoized until `exp`.
#
# DEFERRED — full Application Default Credentials (ADC): ruby_llm also supports
# `Google::Auth.get_application_default` (the GCE/Cloud Run metadata server, the gcloud
# user-default credentials file, GOOGLE_APPLICATION_CREDENTIALS env discovery, etc.).
# Only the explicit service-account-key path is ported here. When no
# `vertexai_service_account_key` is configured, `access_token` raises a clear
# ConfigurationError pointing at this deferral rather than silently emitting a bad token.
#
# Divergences from ruby_llm / googleauth:
# - googleauth's JWT assertion is built and signed internally; here it's explicit:
#   `JWT.encode({iss, scope, aud, iat, exp}, private_key_pem, JWT::Algorithm::RS256)`.
# - Scope: googleauth passes the full SCOPES array (space-joined). We join with " ".
# - The token exchange POST is routed through the overridable `request_token` hook so
#   the unit suite can stub it (NO live GCP calls in specs).
require "json"
require "jwt"
require "crest"
require "../vertexai"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      # Google's OAuth2 token endpoint (the `aud` of the JWT assertion + the POST target).
      OAUTH_TOKEN_URI = "https://oauth2.googleapis.com/token"

      # The jwt-bearer grant type for exchanging a signed assertion for an access token.
      JWT_BEARER_GRANT = "urn:ietf:params:oauth:grant-type:jwt-bearer"

      # Refresh the cached token this many seconds before its real expiry, so a token
      # that is about to expire mid-request is proactively re-minted (mirrors googleauth's
      # `expires_within?` skew handling).
      TOKEN_EXPIRY_SKEW = 30

      # A parsed service-account key (the relevant fields of the JSON Google issues).
      record ServiceAccount,
        client_email : String,
        private_key : String,
        token_uri : String = OAUTH_TOKEN_URI

      # Returns a valid OAuth2 bearer access token for Vertex AI, minting + caching one
      # if needed. The token is reused until it is within TOKEN_EXPIRY_SKEW of expiry.
      def access_token : String
        cached = @access_token
        if cached && (expiry = @access_token_expiry) && Time.utc < (expiry - TOKEN_EXPIRY_SKEW.seconds)
          return cached
        end

        token, expires_in = mint_access_token
        @access_token = token
        @access_token_expiry = Time.utc + expires_in.seconds
        token
      end

      # Builds + signs the JWT assertion, exchanges it for an access token, and returns
      # `{access_token, expires_in_seconds}`.
      protected def mint_access_token : Tuple(String, Int32)
        sa = service_account
        assertion = build_jwt_assertion(sa)

        form_body = URI::Params.build do |form|
          form.add("grant_type", JWT_BEARER_GRANT)
          form.add("assertion", assertion)
        end

        body = request_token(sa.token_uri, form_body)
        parse_token_response(body)
      end

      # Builds the signed JWT assertion for the jwt-bearer grant.
      #
      # Header: {alg: RS256, typ: JWT}. Claims: iss=client_email, scope=<space-joined
      # SCOPES>, aud=<token_uri>, iat=now, exp=now+1h. Signed RS256 with the
      # service-account private key. `now` is injectable for deterministic testing.
      def build_jwt_assertion(sa : ServiceAccount = service_account, now : Time = Time.utc) : String
        iat = now.to_unix
        exp = (now + 1.hour).to_unix
        payload = {
          "iss"   => sa.client_email,
          "scope" => SCOPES.join(" "),
          "aud"   => sa.token_uri,
          "iat"   => iat,
          "exp"   => exp,
        }
        JWT.encode(payload, sa.private_key, JWT::Algorithm::RS256)
      end

      # Parses + caches the service-account credentials from the configured key.
      #
      # `vertexai_service_account_key` mirrors ruby_llm: it is the *JSON content* of the
      # key Google issues. As a convenience divergence we also accept a filesystem *path*
      # to such a JSON file (if the string names an existing file, its contents are read).
      def service_account : ServiceAccount
        @service_account ||= parse_service_account
      end

      private def parse_service_account : ServiceAccount
        raw = @config.vertexai_service_account_key
        if raw.nil? || raw.strip.empty?
          raise ConfigurationError.new(
            "VertexAI auth: vertexai_service_account_key is not set. Provide the " \
            "service-account JSON key (Application Default Credentials / metadata-server " \
            "auth is not yet ported — see vertexai/auth.cr)."
          )
        end

        json_text = File.exists?(raw) ? File.read(raw) : raw

        parsed =
          begin
            JSON.parse(json_text)
          rescue ex : JSON::ParseException
            raise ConfigurationError.new("VertexAI auth: vertexai_service_account_key is not valid JSON: #{ex.message}")
          end

        obj = parsed.as_h?
        unless obj
          raise ConfigurationError.new("VertexAI auth: service-account key must be a JSON object")
        end

        client_email = obj["client_email"]?.try(&.as_s?)
        private_key = obj["private_key"]?.try(&.as_s?)
        unless client_email && private_key
          raise ConfigurationError.new(
            "VertexAI auth: service-account key is missing required fields (client_email, private_key)"
          )
        end

        token_uri = obj["token_uri"]?.try(&.as_s?) || OAUTH_TOKEN_URI
        ServiceAccount.new(client_email: client_email, private_key: private_key, token_uri: token_uri)
      end

      # Performs the token-endpoint POST and returns the raw response body (JSON String).
      # Overridable so unit tests can stub the exchange (NO live GCP calls in specs).
      protected def request_token(token_uri : String, form_body : String) : String
        response =
          begin
            Crest.post(
              token_uri,
              form_body,
              headers: {"Content-Type" => "application/x-www-form-urlencoded"},
              json: false
            )
          rescue ex : Crest::RequestFailed
            raise UnauthorizedError.new(
              ex.response,
              "VertexAI auth: token exchange failed (#{ex.response.status_code}): #{ex.response.body}"
            )
          end
        response.body
      end

      # Extracts `{access_token, expires_in}` from a token-endpoint response body.
      private def parse_token_response(body : String) : Tuple(String, Int32)
        parsed =
          begin
            JSON.parse(body)
          rescue ex : JSON::ParseException
            raise UnauthorizedError.new(nil, "VertexAI auth: token response is not valid JSON: #{ex.message}")
          end

        token = parsed["access_token"]?.try(&.as_s?)
        unless token
          raise UnauthorizedError.new(nil, "VertexAI auth: token response had no access_token (#{body})")
        end

        # `expires_in` is seconds (Google returns ~3600). Default conservatively if absent.
        expires_in = parsed["expires_in"]?.try { |v| v.as_i? || v.as_s?.try(&.to_i?) } || 3600
        {token, expires_in}
      end
    end
  end
end
