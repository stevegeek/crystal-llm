# ported from lib/ruby_llm/providers/azure.rb (+ azure/{chat,models,media,embeddings}.rb) @ ruby_llm 1.16.0
#
# Azure AI Foundry / OpenAI-compatible chat provider. Subclasses
# CrystalLLM::Providers::OpenAI and overrides only what differs from stock OpenAI:
#   - api_base       -> @config.azure_api_base (no default; required)
#   - headers        -> `api-key` header (or Bearer azure_ai_auth_token fallback)
#   - configuration  -> requires azure_api_base; options add the three azure_* keys
#   - completion_url / models_url -> azure_endpoint(...) URL builder (deployment vs
#     resource-base vs openai/v1 vs raw chat-completions URL detection + api-version)
#   - format_messages -> emits `role` verbatim (no system->developer remap) and
#     omits the OpenAI stream_options / system-role quirks via format_role override
#
# This file mirrors ruby_llm's split (azure.rb endpoint logic here; chat/models
# URL hooks in azure/{chat,models}.cr).
#
# DEFERRED (per task scope — CHAT + EMBEDDINGS paths):
# - Embeddings ARE ported now (azure/embeddings.cr: embedding_url /
#   render_embedding_payload; parse_embedding_response is inherited from OpenAI).
#   image, moderation, transcription provider methods are NOT ported. Their hooks
#   live in those still-unported provider methods (same deferral as OpenAI's port).
# - Rich attachment media formatting (azure/media.rb format_image / image/audio/text
#   parts) is DEFERRED with the attachment-provider work; chat reuses OpenAI::Media's
#   text/Raw/Hash content paths (the only ones the chat path needs today).
# - `azure_ai_auth_token` pre-minted path: ruby_llm's only AAD path. The caller
#   supplies the token; `headers` emits `Authorization: Bearer <token>`.
#
# AAD client-credentials flow (DIVERGENCE — NOT in ruby_llm 1.15.0):
#   ruby_llm only consumes a *pre-minted* azure_ai_auth_token; it never acquires one.
#   The parity audit flags "Azure never acquires an AAD token" as a critical gap, so
#   this port adds the acquisition. When azure_tenant_id / azure_client_id /
#   azure_client_secret are all configured, `headers` mints a bearer token via the
#   OAuth2 client-credentials grant:
#     POST https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token
#       grant_type=client_credentials
#       client_id=<id>&client_secret=<secret>
#       scope=https://cognitiveservices.azure.com/.default
#   The access_token is cached on the provider instance until ~expires_in seconds
#   (minus a 60s safety skew); a refresh re-POSTs once the cache lapses. The api-key
#   header path stays the *default* — AAD only kicks in when no api-key is set AND the
#   three AAD props are present. The raw HTTP POST is isolated in `post_aad_token`
#   (an overridable seam) so the unit suite exercises URL/form shaping + caching
#   without any live Azure / Microsoft-login call.
#
# Divergences from ruby_llm:
# - ruby_llm builds `azure_base_parts` lazily into an ivar (`@azure_base_parts ||=`).
#   The Crystal port computes it on demand in a private struct-returning helper
#   (`azure_base_parts`) and memoizes into a nilable ivar.
# - ruby_llm `azure_endpoint(kind)` takes a Symbol; Crystal has no runtime symbols,
#   so the kind is a String ("chat" / "models" / "embeddings"); embeddings raises
#   (deferred). Mirrors the design's symbols-as-runtime-data -> String rule.
# - `configured?`/`ensure_configured!`: the base Provider drives these off
#   `configuration_requirements` + `Configuration#configured?`. Azure needs the
#   OR-condition (api_base AND (api_key OR auth_token)), so `self.configured?` and
#   `ensure_configured!` are overridden to reproduce ruby_llm's Azure::configured?.
require "json"
require "./openai"

module CrystalLLM
  # Reopen Configuration to register Azure's provider options (the Crystal analog of
  # ruby_llm's `register_provider_options` — each provider file adds typed `property`s
  # at compile time; see PORTING.md "register_provider_options pattern").
  class Configuration
    nilable_string_option azure_api_base
    nilable_string_option azure_api_key
    # Pre-minted Bearer token (ruby_llm's only AAD path: the caller supplies the token).
    nilable_string_option azure_ai_auth_token

    # --- AAD client-credentials config (DIVERGENCE: not present in ruby_llm 1.15.0) ---
    # When all three are set, the provider mints (and caches) an AAD bearer token via the
    # OAuth2 client-credentials grant instead of requiring a pre-minted azure_ai_auth_token.
    # See providers/azure.cr header for the rationale.
    nilable_string_option azure_tenant_id
    nilable_string_option azure_client_id
    nilable_string_option azure_client_secret
  end

  module Providers
    # Azure AI Foundry / OpenAI-compatible API integration (chat + tools + streaming).
    class Azure < OpenAI
      AZURE_DEFAULT_CHAT_API_VERSION   = "2024-05-01-preview"
      AZURE_DEFAULT_MODELS_API_VERSION = "preview"

      def api_base : String
        @config.azure_api_base || ""
      end

      # Auth header precedence (mirrors ruby_llm + the AAD divergence):
      #   1. api-key header        — when azure_api_key is set (the DEFAULT path)
      #   2. AAD client-credentials — when the three AAD props are set (mint + cache)
      #   3. pre-minted Bearer      — when azure_ai_auth_token is set
      # ruby_llm only has (1) and (3); (2) is this port's addition (see file header).
      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.azure_api_key
          h["api-key"] = key
        elsif aad_configured?
          h["Authorization"] = "Bearer #{aad_access_token}"
        elsif token = @config.azure_ai_auth_token
          h["Authorization"] = "Bearer #{token}"
        end
        h
      end

      # ---- AAD client-credentials flow (DIVERGENCE — see file header) ----

      AAD_TOKEN_HOST = "https://login.microsoftonline.com"
      AAD_SCOPE      = "https://cognitiveservices.azure.com/.default"
      # Refresh this many seconds *before* the reported expiry, to avoid handing out a
      # token that lapses in flight.
      AAD_EXPIRY_SKEW = 60

      # Cached token + the monotonic instant it stops being usable. Lives on the
      # provider instance (NOT on Configuration — Configuration ivars are all public
      # options, see PORTING.md). A nil token means "not yet fetched".
      @aad_token : String? = nil
      @aad_token_expires_at : Time? = nil

      # True when the AAD client-credentials grant is fully configured.
      def aad_configured? : Bool
        !@config.azure_tenant_id.nil? &&
          !@config.azure_client_id.nil? &&
          !@config.azure_client_secret.nil?
      end

      # The OAuth2 token endpoint for the configured tenant.
      def aad_token_url : String
        tenant = @config.azure_tenant_id
        raise ConfigurationError.new("Missing configuration for Azure AAD: azure_tenant_id") if tenant.nil?
        "#{AAD_TOKEN_HOST}/#{tenant}/oauth2/v2.0/token"
      end

      # The client-credentials grant form body. crest serializes this as
      # application/x-www-form-urlencoded (the grant's required content type).
      def aad_token_form : Hash(String, String)
        client_id = @config.azure_client_id
        client_secret = @config.azure_client_secret
        raise ConfigurationError.new("Missing configuration for Azure AAD: azure_client_id") if client_id.nil?
        raise ConfigurationError.new("Missing configuration for Azure AAD: azure_client_secret") if client_secret.nil?

        {
          "grant_type"    => "client_credentials",
          "client_id"     => client_id,
          "client_secret" => client_secret,
          "scope"         => AAD_SCOPE,
        }
      end

      # Returns a valid cached AAD bearer token, minting a fresh one when the cache is
      # empty or lapsed. The single fetch + cache-update is what `headers` relies on.
      def aad_access_token : String
        cached = @aad_token
        expires_at = @aad_token_expires_at
        if cached && expires_at && Time.utc < expires_at
          return cached
        end

        refresh_aad_token!
      end

      # POSTs the client-credentials grant, parses access_token + expires_in, and
      # caches the result. Returns the new token.
      private def refresh_aad_token! : String
        response = post_aad_token(aad_token_url, aad_token_form)
        body = JSON.parse(response.body)

        token = body["access_token"]?.try(&.as_s?)
        if token.nil? || token.empty?
          raise ConfigurationError.new("Azure AAD token response had no access_token")
        end

        # expires_in is seconds-from-now (JSON number); default to a conservative 3600
        # when absent. Apply the safety skew so we refresh before the real expiry.
        expires_in = body["expires_in"]?.try(&.as_i64?) || 3600_i64
        lifetime = expires_in - AAD_EXPIRY_SKEW
        lifetime = 0_i64 if lifetime < 0

        @aad_token = token
        @aad_token_expires_at = Time.utc + lifetime.seconds
        token
      end

      # The single HTTP seam for the AAD token request, isolated so the unit suite can
      # override it with a canned response (no live Microsoft-login call). Production
      # POSTs the form-encoded grant via crest.
      protected def post_aad_token(url : String, form : Hash(String, String)) : Crest::Response
        Crest.post(url, form: form, read_timeout: @config.request_timeout.seconds)
      end

      # ruby_llm: `%i[azure_api_base]` — the task pins this to the two primary keys.
      def self.configuration_requirements : Array(String)
        ["azure_api_key", "azure_api_base"]
      end

      def self.configuration_options : Array(String)
        %w[azure_api_base azure_api_key azure_ai_auth_token]
      end

      # Azure works with deployment names instead of model names, so any model id is
      # assumed valid (ruby_llm's `assume_models_exist?`). Not yet consumed by the
      # Crystal model-registry path; ported for parity + future wiring.
      def self.assume_models_exist? : Bool
        true
      end

      # Azure's configured? is an OR over auth methods (api_base AND (api_key OR
      # auth_token)) — not the base's "all requirements present" AND. Overridden to
      # match ruby_llm's Azure.configured?. DIVERGENCE: a complete AAD
      # client-credentials triple (tenant/client_id/client_secret) also satisfies the
      # auth requirement, since the provider mints a token from it.
      def self.configured?(config : Configuration) : Bool
        !config.azure_api_base.nil? &&
          (!config.azure_api_key.nil? ||
            !config.azure_ai_auth_token.nil? ||
            aad_configured?(config))
      end

      # Class-level mirror of the instance `aad_configured?` (used by `configured?`,
      # which is a class method).
      def self.aad_configured?(config : Configuration) : Bool
        !config.azure_tenant_id.nil? &&
          !config.azure_client_id.nil? &&
          !config.azure_client_secret.nil?
      end

      private def ensure_configured! : Nil
        missing = [] of String
        missing << "azure_api_base" if @config.azure_api_base.nil?
        if @config.azure_api_key.nil? && @config.azure_ai_auth_token.nil? && !aad_configured?
          missing << "azure_api_key, azure_ai_auth_token, or AAD client credentials"
        end
        return if missing.empty?

        raise ConfigurationError.new("Missing configuration for Azure: #{missing.join(", ")}")
      end

      # ---- Azure endpoint URL builder (ported from azure.rb) ----

      # The parsed pieces of api_base, used to decide which endpoint URL to emit.
      private record AzureBaseParts,
        raw_base : String,
        path_base : String,
        root : String,
        mode : String,
        version : String?

      @azure_base_parts : AzureBaseParts? = nil

      # Returns "chat" / "embeddings" / "models" endpoint URL for the configured
      # api_base. (embeddings landed with azure/embeddings.cr — see that file.)
      def azure_endpoint(kind : String) : String
        parts = azure_base_parts
        case kind
        when "chat"
          chat_endpoint(parts)
        when "embeddings"
          embeddings_endpoint(parts)
        when "models"
          models_endpoint(parts)
        else
          raise ArgumentError.new("Unknown Azure endpoint kind: #{kind.inspect}")
        end
      end

      private def azure_base_parts : AzureBaseParts
        @azure_base_parts ||= begin
          raw_base = api_base.to_s.gsub(%r{/+\z}, "")
          version = raw_base.match(/[?&]api-version=([^&]+)/i).try(&.[1])
          path_base = raw_base.gsub(/\?.*\z/, "")

          mode =
            if path_base.includes?("/chat/completions")
              "chat_endpoint"
            elsif path_base.includes?("/openai/deployments/")
              "deployment_base"
            elsif path_base.includes?("/openai/v1")
              "openai_v1_base"
            else
              "resource_base"
            end

          AzureBaseParts.new(
            raw_base: raw_base,
            path_base: path_base,
            root: azure_host_root(path_base),
            mode: mode,
            version: version
          )
        end
      end

      private def chat_endpoint(parts : AzureBaseParts) : String
        case parts.mode
        when "chat_endpoint"
          ""
        when "deployment_base"
          with_api_version("chat/completions", parts.version || AZURE_DEFAULT_CHAT_API_VERSION)
        when "openai_v1_base"
          with_api_version("chat/completions", parts.version)
        else
          with_api_version("models/chat/completions", parts.version || AZURE_DEFAULT_CHAT_API_VERSION)
        end
      end

      # Mirrors ruby_llm's Azure#embeddings_endpoint. Note: unlike chat, the
      # deployment/openai_v1 branch passes `parts.version` through *without* a
      # default fallback (ruby_llm uses `with_api_version('embeddings', parts[:version])`).
      private def embeddings_endpoint(parts : AzureBaseParts) : String
        case parts.mode
        when "deployment_base", "openai_v1_base"
          with_api_version("embeddings", parts.version)
        else
          "#{parts.root}/openai/v1/embeddings"
        end
      end

      private def models_endpoint(parts : AzureBaseParts) : String
        case parts.mode
        when "openai_v1_base"
          with_api_version("models", parts.version || AZURE_DEFAULT_MODELS_API_VERSION)
        else
          "#{parts.root}/openai/v1/models?api-version=#{parts.version || AZURE_DEFAULT_MODELS_API_VERSION}"
        end
      end

      private def with_api_version(path : String, version : String?) : String
        return path unless version

        separator = path.includes?("?") ? "&" : "?"
        "#{path}#{separator}api-version=#{version}"
      end

      private def azure_host_root(base_without_query : String) : String
        base_without_query.gsub(%r{/(models|openai)/.*\z}, "").gsub(%r{/+\z}, "")
      end
    end
  end
end

require "./azure/media"
require "./azure/chat"
require "./azure/models"
require "./azure/embeddings"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('azure', ...)`).
CrystalLLM::Provider.register("azure", CrystalLLM::Providers::Azure)
