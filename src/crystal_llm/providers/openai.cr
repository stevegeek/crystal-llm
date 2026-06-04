# ported from lib/ruby_llm/providers/openai.rb (+ openai/{chat,models,streaming,tools,media,capabilities,temperature}.rb) @ ruby_llm 1.15.0
#
# OpenAI chat provider: text chat + tools + streaming. ruby_llm splits OpenAI into
# many `module_function` mixins included into one class; the Crystal port collapses
# the chat/tools/streaming/models/media/temperature mixins into this single class
# (reopened in sections) and ports Capabilities as a `CrystalLLM::Capabilities`
# subclass (see provider_completion.cr for why Capabilities is a class hierarchy).
#
# DEFERRED (per task scope — embeddings/images/moderation/transcription provider
# methods): the OpenAI::{Embeddings,Images,Moderation,Transcription} mixins are NOT
# ported here. Their render_*/parse_* hooks live in those still-unported provider
# methods. media.cr is ported only for the text/Raw/Hash content paths that chat
# needs; rich attachment formatting (image/audio/pdf parts) is DEFERRED with the
# attachment-provider work (the Attachment#for_llm/url? surface those need).
#
# Other divergences:
# - `tool_prefs` (tool_choice / parallel_tool_calls) is omitted from render_payload
#   (the completion pipeline defers it — see provider_completion.cr). build_tool_choice
#   is still ported for when the chat/agent layer wires tool_prefs back in.
# - thinking text/signature *extraction* into Message is DEFERRED (Message#thinking
#   is itself deferred — see message.cr). Token-level reasoning_tokens ARE wired.
#   `<think>`-tag stripping from content is ported (content-only, independent of
#   Message#thinking).
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
  # Reopen Configuration to register OpenAI's provider options (the Crystal analog
  # of ruby_llm's `register_provider_options` — each provider file adds typed
  # `property`s at compile time; see PORTING.md "register_provider_options pattern").
  class Configuration
    property openai_api_key : String? = nil
    property openai_api_base : String? = nil
    property openai_organization_id : String? = nil
    property openai_project_id : String? = nil
    # ruby_llm exposes `openai_use_system_role` (Bool); kept as a Bool option.
    property openai_use_system_role : Bool = false
  end

  module Providers
    # OpenAI API integration (chat + tools + streaming).
    class OpenAI < Provider
      def api_base : String
        @config.openai_api_base || "https://api.openai.com/v1"
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.openai_api_key
          h["Authorization"] = "Bearer #{key}"
        end
        if org = @config.openai_organization_id
          h["OpenAI-Organization"] = org
        end
        if project = @config.openai_project_id
          h["OpenAI-Project"] = project
        end
        h
      end

      def maybe_normalize_temperature(temperature : Float64?, model : Model::Info) : Float64?
        Temperature.normalize(temperature, model.id || "")
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end

      def self.configuration_requirements : Array(String)
        ["openai_api_key"]
      end

      def self.configuration_options : Array(String)
        %w[openai_api_key openai_api_base openai_organization_id openai_project_id openai_use_system_role]
      end
    end
  end
end

require "./openai/temperature"
require "./openai/media"
require "./openai/tools"
require "./openai/chat"
require "./openai/streaming"
require "./openai/models"
require "./openai/capabilities"
require "./openai/embeddings"
require "./openai/images"
require "./openai/moderation"
require "./openai/transcription"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('openai', ...)`).
CrystalLLM::Provider.register("openai", CrystalLLM::Providers::OpenAI)
