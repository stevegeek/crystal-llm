# ported from lib/ruby_llm/providers/mistral*.rb @ ruby_llm 1.15.0
#
# Mistral API integration (chat + tools + streaming + models). Mistral is an
# OpenAI-compatible provider, so this subclasses Providers::OpenAI and overrides
# only what differs: api_base, headers, configuration options/requirements, the
# capabilities helper, and the chat/models quirks (see mistral/chat.cr,
# mistral/models.cr, mistral/capabilities.cr).
#
# Scope notes:
# - The Embeddings mixin (mistral/embeddings.rb) IS ported — see mistral/embeddings.cr
#   (it feeds the provider_media.cr embed pipeline). Image/moderation/transcription
#   are not offered by Mistral.
# - Mistral has no dedicated Media mixin here: it inherits OpenAI's media formatting
#   (mistral/media.rb is not separately ported). Note Mistral upstream uses a
#   `document_url` part type (vs OpenAI's `file`) for pdf/document attachments —
#   the inherited OpenAI Media uses the `file` shape; reproduce `document_url` if a
#   Mistral-specific media override is added later.
# - Assistant thinking-block injection in format_messages IS ported (reads
#   Message#thinking — see mistral/chat.cr), as is the thinking *payload* shaping.
# - Hard auth: only the `Bearer #{mistral_api_key}` header is wired; no API-key
#   validation/refresh beyond the configuration_requirements check.
require "json"
require "./openai"

module CrystalLLM
  # Reopen Configuration to register Mistral's provider options (the Crystal analog
  # of ruby_llm's `register_provider_options`; each provider file adds typed
  # `property`s at compile time — see PORTING.md "register_provider_options pattern").
  class Configuration
    property mistral_api_key : String? = nil
  end

  module Providers
    # Mistral API integration (chat + tools + streaming).
    class Mistral < OpenAI
      def api_base : String
        "https://api.mistral.ai/v1"
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.mistral_api_key
          h["Authorization"] = "Bearer #{key}"
        end
        h
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end

      def self.configuration_requirements : Array(String)
        ["mistral_api_key"]
      end

      def self.configuration_options : Array(String)
        ["mistral_api_key"]
      end
    end
  end
end

require "./mistral/capabilities"
require "./mistral/chat"
require "./mistral/models"
require "./mistral/embeddings"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('mistral', ...)`).
CrystalLLM::Provider.register("mistral", CrystalLLM::Providers::Mistral)
