# ported from lib/ruby_llm/providers/azure.rb (+ azure/{chat,models,media,embeddings}.rb) @ ruby_llm 1.15.0
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
# - `azure_ai_auth_token` hard-auth path: the property is added and the Bearer
#   fallback in `headers` is ported, but token acquisition/refresh is out of scope.
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
    property azure_api_base : String? = nil
    property azure_api_key : String? = nil
    # Bearer fallback when no api-key is set (token acquisition deferred — see header).
    property azure_ai_auth_token : String? = nil
  end

  module Providers
    # Azure AI Foundry / OpenAI-compatible API integration (chat + tools + streaming).
    class Azure < OpenAI
      AZURE_DEFAULT_CHAT_API_VERSION   = "2024-05-01-preview"
      AZURE_DEFAULT_MODELS_API_VERSION = "preview"

      def api_base : String
        @config.azure_api_base || ""
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.azure_api_key
          h["api-key"] = key
        elsif token = @config.azure_ai_auth_token
          h["Authorization"] = "Bearer #{token}"
        end
        h
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
      # match ruby_llm's Azure.configured?.
      def self.configured?(config : Configuration) : Bool
        !config.azure_api_base.nil? &&
          (!config.azure_api_key.nil? || !config.azure_ai_auth_token.nil?)
      end

      private def ensure_configured! : Nil
        missing = [] of String
        missing << "azure_api_base" if @config.azure_api_base.nil?
        if @config.azure_api_key.nil? && @config.azure_ai_auth_token.nil?
          missing << "azure_api_key or azure_ai_auth_token"
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

require "./azure/chat"
require "./azure/models"
require "./azure/embeddings"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('azure', ...)`).
CrystalLLM::Provider.register("azure", CrystalLLM::Providers::Azure)
