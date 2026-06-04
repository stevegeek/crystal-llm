# ported from lib/ruby_llm/providers/vertexai*.rb @ ruby_llm 1.15.0
#
# Google Vertex AI provider (CHAT path: chat + streaming + tools + models +
# capabilities). In ruby_llm, `VertexAI < Gemini` and inherits the Gemini wire
# format, overriding only completion_url/stream_url/headers/api_base/models. The
# CrystalLLM port has no Gemini provider yet, so the Gemini chat/streaming/tools/
# media wire format is ported *directly into the VertexAI sub-files* (self-contained,
# chat-only scope). When a standalone Gemini provider lands, these can be lifted to a
# shared base.
#
# DEFERRED (per task scope):
# - embeddings / image / moderation / transcription provider methods (the Gemini
#   Embeddings/Transcription + VertexAI Embeddings mixins) are NOT ported.
# - rich attachment media formatting (inline_data / fileData parts) — media.cr ports
#   only the text/Raw/Hash content paths chat needs; a Content with attachments raises
#   a clear "deferred" error (mirrors the OpenAI media port).
# - structured-output schema conversion (GeminiSchema / responseSchema / thinkingConfig)
#   is NOT ported (chat-only; render_payload accepts `schema`/`thinking` to match the
#   frozen hook signature but only wires the plain responseMimeType envelope when a
#   schema is present — see chat.cr).
#
# DEFERRED — AUTH (hard): ruby_llm authenticates via the googleauth gem (Application
# Default Credentials / service-account key -> OAuth2 bearer token, SCOPES). That OAuth
# token-minting is NOT ported here (no live calls in the unit suite anyway). `headers`
# is a BEST EFFORT: it emits `Authorization: Bearer <vertexai_service_account_key>` when
# a key string is configured (treating it as a pre-minted token for testing), else a
# placeholder. A real OAuth exchange must be wired before live use. See `headers` below.
require "json"
require "../provider"
require "../provider_completion"
require "../configuration"
require "../message"
require "../chunk"
require "../content"
require "../tool"
require "../tool_call"
require "../model/info"
require "../thinking"
require "../utils"

module CrystalLLM
  # Reopen Configuration to register VertexAI's provider options (the Crystal analog
  # of ruby_llm's `register_provider_options` — each provider file adds typed
  # `property`s at compile time; see PORTING.md "register_provider_options pattern").
  #
  # ruby_llm's configuration_options: vertexai_project_id, vertexai_location,
  # vertexai_service_account_key. `vertexai_service_account_key` doubles, in this port,
  # as the best-effort bearer token until real OAuth lands (see vertexai.cr header).
  class Configuration
    property vertexai_project_id : String? = nil
    property vertexai_location : String? = nil
    property vertexai_service_account_key : String? = nil
  end

  module Providers
    # Google Vertex AI integration (chat + tools + streaming, Gemini wire format).
    class VertexAI < Provider
      # OAuth scopes ruby_llm requests (kept for parity / future real auth).
      SCOPES = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/generative-language.retriever",
      ]

      def api_base : String
        if @config.vertexai_location.to_s == "global"
          "https://aiplatform.googleapis.com/v1beta1"
        else
          "https://#{@config.vertexai_location}-aiplatform.googleapis.com/v1beta1"
        end
      end

      # DEFERRED (hard auth): ruby_llm mints an OAuth2 bearer via googleauth (ADC or a
      # service-account key + SCOPES). That exchange is NOT ported. Best effort: if a
      # `vertexai_service_account_key` is set we treat it as a pre-minted bearer token
      # (sufficient for tests / a caller that injects a token); otherwise a placeholder
      # token is emitted so the header shape is correct. Wire real OAuth before live use.
      def headers : Hash(String, String)
        token = @config.vertexai_service_account_key || "auth-deferred-no-token"
        {"Authorization" => "Bearer #{token}"}
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end

      def self.configuration_requirements : Array(String)
        %w[vertexai_project_id vertexai_location]
      end

      def self.configuration_options : Array(String)
        %w[vertexai_project_id vertexai_location vertexai_service_account_key]
      end
    end
  end
end

require "./vertexai/media"
require "./vertexai/tools"
require "./vertexai/chat"
require "./vertexai/streaming"
require "./vertexai/models"
require "./vertexai/capabilities"
require "./vertexai/embeddings"
require "./vertexai/transcription"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('vertexai', ...)`).
CrystalLLM::Provider.register("vertexai", CrystalLLM::Providers::VertexAI)
