# ported from lib/ruby_llm/providers/ollama.rb (+ ollama/{chat,models,capabilities,media}.rb) @ ruby_llm 1.15.0
#
# Ollama API integration. Ollama exposes an OpenAI-compatible chat/completions
# surface, so ruby_llm's `Ollama < OpenAI` carries over directly: the Crystal port
# subclasses `CrystalLLM::Providers::OpenAI` and overrides only what differs
# (api_base, headers, configuration_*, format_role, the models parser, and the
# capabilities helper). The OpenAI chat/tools/streaming/temperature hooks are
# inherited unchanged.
#
# Divergences from ruby_llm:
# - `api_base` is `@config.ollama_api_base` with NO default (it is a configuration
#   requirement); the provider raises at construction if it is unset.
# - `headers` emits only `Authorization: Bearer <key>` when `ollama_api_key` is set
#   (no org/project headers), matching ollama.rb.
# - `format_role` (ollama/chat.rb's `format_role(role) = role.to_s`) returns the
#   bare downcased role for every role, including system — Ollama does NOT do
#   OpenAI's system->developer remap. Overridden here. The rest of `format_messages`
#   (content via OpenAI::Media, tool_calls, tool_call_id) is inherited from OpenAI.
# - `parse_list_models_response` (ollama/models.rb) hardcodes family="ollama", a
#   fixed modalities/capabilities set, and metadata={owned_by}; it does NOT route
#   through the capabilities registry the way OpenAI's models parser does.
# - Capabilities: ollama/capabilities.rb defines `supports_tool_choice?` /
#   `supports_tool_parallel_control?` (both false). The Crystal `Capabilities` base
#   surface (provider_completion.cr) does not yet include those predicates (tool_prefs
#   is deferred — see provider_completion.cr); they are ported here as class methods
#   for when the chat/agent layer wires tool_prefs back in.
#
# DEFERRED (per task scope — CHAT path only):
# - Embeddings / image / moderation / transcription provider methods: Ollama
#   inherits these from OpenAI, which itself defers them (see openai.cr header).
# - Attachment media formatting: ollama/media.rb's `format_content`/`format_image`
#   rich-attachment paths depend on the not-yet-ported Attachment surface
#   (Attachment#for_llm/#mime_type). Only the text/Raw/Hash content paths needed for
#   chat are inherited from OpenAI::Media; a Content carrying attachments raises the
#   same clear "deferred" error as OpenAI (see providers/openai/media.cr).
# - Hard auth: there is none for Ollama beyond the optional bearer key (no signed
#   requests), so nothing additional is deferred on the auth axis.
require "json"
require "./openai"

module CrystalLLM
  # Reopen Configuration to register Ollama's provider options (the Crystal analog
  # of ruby_llm's `register_provider_options` — see PORTING.md). Each provider file
  # adds its typed `property`s at compile time; this is parallel-safe.
  class Configuration
    property ollama_api_base : String? = nil
    property ollama_api_key : String? = nil
  end

  module Providers
    # Ollama API integration (OpenAI-compatible chat + tools + streaming).
    class Ollama < OpenAI
      def api_base : String
        # ruby_llm: `@config.ollama_api_base` (no fallback). `ollama_api_base` is a
        # configuration requirement, so a configured provider always has it; the
        # `|| ""` only guards the (unreachable-for-a-configured-provider) nil branch.
        @config.ollama_api_base || ""
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.ollama_api_key
          h["Authorization"] = "Bearer #{key}"
        end
        h
      end

      # ollama/chat.rb: `format_role(role) = role.to_s` — no OpenAI system->developer
      # remap. Override OpenAI#format_role to return the bare downcased role.
      def format_role(role : Role) : String
        role.to_s.downcase
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end

      # ruby_llm: `local? = true`. Kept for parity with the provider surface.
      def self.local? : Bool
        true
      end

      def self.configuration_requirements : Array(String)
        ["ollama_api_base"]
      end

      def self.configuration_options : Array(String)
        %w[ollama_api_base ollama_api_key]
      end
    end
  end
end

require "./ollama/media"
require "./ollama/models"
require "./ollama/capabilities"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('ollama', ...)`).
CrystalLLM::Provider.register("ollama", CrystalLLM::Providers::Ollama)
