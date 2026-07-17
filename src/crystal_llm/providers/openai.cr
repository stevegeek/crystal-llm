# ported from lib/ruby_llm/providers/openai.rb (+ openai/{chat,models,streaming,tools,media,capabilities,temperature}.rb) @ ruby_llm 1.16.0
#
# OpenAI chat provider: text chat + tools + streaming. ruby_llm splits OpenAI into
# many `module_function` mixins included into one class; the Crystal port collapses
# the chat/tools/streaming/models/media/temperature mixins into this single class
# (reopened in sections) and ports Capabilities as a `CrystalLLM::Capabilities`
# subclass (see provider_completion.cr for why Capabilities is a class hierarchy).
#
# Media: the OpenAI::{Embeddings,Images,Moderation,Transcription} mixins ARE ported
# (see openai/{embeddings,images,moderation,transcription}.cr — their render_*/parse_*
# hooks feed the provider_media.cr pipeline). media.cr formats the full rich-attachment
# surface (image/audio/pdf content parts via Attachment#for_llm), not just text.
#
# Other divergences:
# - `tool_prefs` (tool_choice / parallel_tool_calls) IS emitted by render_payload (see
#   openai/chat.cr): `choice` → `tool_choice` (via `build_tool_choice`), `calls` →
#   `parallel_tool_calls`.
# - thinking text/signature *extraction* into Message IS wired (see openai/chat.cr:
#   `thinking`/`reasoning_content` blocks → `Thinking.build` → Message#thinking).
#   Token-level reasoning_tokens are wired too, and `<think>`-tag stripping from
#   content is ported.
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
    nilable_string_option openai_api_key
    nilable_string_option openai_api_base
    nilable_string_option openai_organization_id
    nilable_string_option openai_project_id
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
