# ported from lib/ruby_llm/providers/anthropic*.rb @ ruby_llm 1.15.0
#
# Anthropic Claude API integration (chat + tools + streaming + models). ruby_llm
# splits Anthropic into many `module_function` mixins (chat/streaming/tools/models/
# media/content/capabilities) included into one class; the Crystal port mirrors that
# split across providers/anthropic/*.cr (reopening this class in sections) and ports
# Capabilities + Media as helper modules.
#
# This provider has its OWN wire format (the Messages API), unrelated to OpenAI's
# chat-completions shape: a top-level `system` array, `max_tokens`, content-block
# messages, `x-api-key` + `anthropic-version` headers, `v1/messages` endpoint. The
# OpenAI provider is used only as a STRUCTURAL template (same provider hooks), not a
# payload template.
#
# DEFERRED (per task scope — CHAT path only):
# - Embeddings / image / moderation / transcription provider methods: NOT ported
#   (Anthropic only ships embeddings as an extra mixin upstream; the others are
#   absent). Anthropic::Embeddings is intentionally not ported.
# - Rich attachment media formatting (format_image/format_pdf/format_text_file and
#   per-attachment dispatch): DEFERRED with the attachment-provider port (needs
#   Attachment#url?/#encoded/#mime_type/#for_llm). Only the text / Raw / Hash / Array
#   content paths chat needs are ported; a Content carrying attachments raises a clear
#   "deferred" error rather than silently dropping them.
# - Hard auth: none required beyond the api key (x-api-key); no OAuth/region/STS.
#
# Other divergences (documented at each site):
# - `tool_prefs` (tool_choice / parallel control) is omitted from render_payload (the
#   completion pipeline defers it — see provider_completion.cr). build_tool_choice is
#   still ported for when the chat/agent layer wires tool_prefs back in.
# - Message has no `thinking` keyword yet (Message#thinking is deferred — see
#   message.cr); parse_completion_response/build_chunk extract thinking text/signature
#   but do NOT attach it to the Message/Chunk. Token-level thinking_tokens ARE wired.
# - `response.body` is a raw String (Crest); JSON.parse it in-method (ruby_llm's
#   Faraday json middleware pre-parses).
# - Symbols-as-runtime-data (:auto/:any/:tool roles) become String/enum (design §11).
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
  # Reopen Configuration to register Anthropic's provider options (the Crystal analog
  # of ruby_llm's `register_provider_options` — each provider file adds typed
  # `property`s at compile time; see PORTING.md "register_provider_options pattern").
  # ruby_llm's `configuration_options` is `%i[anthropic_api_key anthropic_api_base]`.
  class Configuration
    property anthropic_api_key : String? = nil
    property anthropic_api_base : String? = nil
  end

  module Providers
    # Anthropic Claude API integration (chat + tools + streaming).
    class Anthropic < Provider
      ANTHROPIC_VERSION = "2023-06-01"

      def api_base : String
        @config.anthropic_api_base || "https://api.anthropic.com"
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.anthropic_api_key
          h["x-api-key"] = key
        end
        h["anthropic-version"] = ANTHROPIC_VERSION
        h
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end

      def self.configuration_requirements : Array(String)
        ["anthropic_api_key"]
      end

      def self.configuration_options : Array(String)
        %w[anthropic_api_key anthropic_api_base]
      end
    end
  end
end

require "./anthropic/media"
require "./anthropic/tools"
require "./anthropic/chat"
require "./anthropic/streaming"
require "./anthropic/models"
require "./anthropic/capabilities"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('anthropic', ...)`).
CrystalLLM::Provider.register("anthropic", CrystalLLM::Providers::Anthropic)
