# ported from lib/ruby_llm/providers/gpustack*.rb @ ruby_llm 1.15.0
# (gpustack.rb + gpustack/{chat,models,capabilities}.rb)
#
# GPUStack is an OpenAI-compatible (it is "based on Ollama" per ruby_llm) provider.
# The Crystal port subclasses CrystalLLM::Providers::OpenAI and overrides only what
# differs, mirroring ruby_llm's file split:
#   - api_base / headers / configuration (gpustack_* keys) — here
#   - format_role (bare role string, no system->developer remap) — gpustack/chat.cr
#   - parse_list_models_response (a `{items:[...]}` payload, not OpenAI's `{data:[...]}`)
#     — gpustack/models.cr
#   - Capabilities (tool_choice / tool_parallel_control unsupported) — gpustack/capabilities.cr
#
# Inherited unchanged from Providers::OpenAI (read providers/openai*.cr):
# - completion_url / stream_url / models_url ("chat/completions" / "models")
# - render_payload (the OpenAI chat-completions body; gpustack speaks the same wire
#   shape — model/messages/stream/temperature/tools/response_format/...)
# - parse_completion_response (choices[0].message -> Message, OpenAI token accounting)
# - build_chunk (OpenAI streaming delta -> Chunk)
# - tool_for / format_tool_calls / parse_tool_calls (OpenAI function-call shape)
#
# Divergences from ruby_llm's GPUStack:
# - ruby_llm's GPUStack.configuration_requirements is `%i[gpustack_api_base]` only;
#   the TASK contract asks for ["gpustack_api_base","gpustack_api_key"]. We honor the
#   task contract (both required) — see configuration_requirements below. The api_base
#   is the local GPUStack server URL; the api_key is its bearer token.
# - ruby_llm exposes `local? => true`; ported as `self.local? : Bool` (informational;
#   nothing in the chat path consumes it yet).
#
# DEFERRED (chat-only scope, mirrors the OpenAI port + task contract):
# - embeddings / image / moderation / transcription provider methods (none ported).
#   GPUStack inherits the OpenAI embedding hooks verbatim (ruby_llm ships no
#   gpustack/embeddings.rb either — see providers/openai/embeddings.cr).
# - Rich attachment media formatting (gpustack/media.rb's format_image / image_url
#   parts and the per-attachment dispatch). The inherited OpenAI::Media handles the
#   text / Raw / Hash paths; a Content carrying attachments raises a clear deferred
#   error.
# - "hard auth": no token-refresh / credential negotiation; a static bearer header.
require "json"
require "./openai"
require "../provider_completion"

module CrystalLLM
  # Reopen Configuration to register GPUStack's provider options — the Crystal analog
  # of ruby_llm's `register_provider_options` (each provider file adds typed
  # `property`s at compile time; parallel-safe). See PORTING.md.
  class Configuration
    property gpustack_api_base : String? = nil
    property gpustack_api_key : String? = nil
  end

  module Providers
    # GPUStack API integration (OpenAI-compatible; "based on Ollama"). Chat + tools +
    # streaming + models are inherited from Providers::OpenAI; the (thin) overrides
    # live in gpustack/{chat,models,capabilities}.cr (see file header).
    class GPUStack < OpenAI
      def api_base : String
        @config.gpustack_api_base || ""
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.gpustack_api_key
          h["Authorization"] = "Bearer #{key}"
        end
        h
      end

      # ruby_llm: `GPUStack.local? => true`. Informational; not consumed in the chat
      # path yet (nothing dispatches on it).
      def self.local? : Bool
        true
      end

      # TASK contract: both api_base and api_key are required (ruby_llm requires only
      # gpustack_api_base — see file header divergence note).
      def self.configuration_requirements : Array(String)
        ["gpustack_api_base", "gpustack_api_key"]
      end

      def self.configuration_options : Array(String)
        %w[gpustack_api_base gpustack_api_key]
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end
    end
  end
end

require "./gpustack/media"
require "./gpustack/chat"
require "./gpustack/models"
require "./gpustack/capabilities"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('gpustack', ...)`).
CrystalLLM::Provider.register("gpustack", CrystalLLM::Providers::GPUStack)
