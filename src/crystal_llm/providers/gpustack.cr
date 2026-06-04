# ported from lib/ruby_llm/providers/gpustack*.rb @ ruby_llm 1.15.0
# (gpustack.rb + gpustack/{chat,models,media,capabilities}.rb)
#
# GPUStack is an OpenAI-compatible (it is "based on Ollama" per ruby_llm) provider.
# The Crystal port subclasses CrystalLLM::Providers::OpenAI and overrides only what
# differs: api_base/headers/configuration (gpustack_* keys), the role formatting
# (gpustack uses the bare role string, not OpenAI's system->developer remap), the
# model-list parsing (a GPUStack `{items:[...]}` payload, not OpenAI's `{data:[...]}`),
# and the Capabilities helper (tool_choice / tool_parallel_control unsupported).
#
# Inherited unchanged from Providers::OpenAI (read providers/openai*.cr):
# - completion_url / stream_url ("chat/completions")
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
# - gpustack/chat.rb merges `OpenAI::Chat.format_thinking(msg)` into each message; the
#   Crystal OpenAI port does NOT port format_thinking (Message#thinking extraction is
#   deferred — see openai/chat.cr), so the inherited format_messages omits it too.
#   Role formatting IS overridden here to match gpustack (bare role string).
#
# DEFERRED (chat-only scope, mirrors the OpenAI port + task contract):
# - embeddings / image / moderation / transcription provider methods (none ported).
# - Rich attachment media formatting (gpustack/media.rb's format_image / image_url
#   parts and the per-attachment dispatch). The inherited OpenAI::Media handles the
#   text / Raw / Hash paths; a Content carrying attachments raises a clear deferred
#   error. gpustack/media.rb's `format_content` (Raw.value / Hash#to_json / parts)
#   is therefore not ported beyond those text paths.
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
    # streaming + models are inherited from Providers::OpenAI; see the file header for
    # the (thin) set of overrides and the deferred non-chat surface.
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

      # gpustack/chat.rb: `format_role(role) = role.to_s`. Unlike OpenAI (which maps
      # the system role to "developer"), GPUStack uses the bare lowercase role string.
      def format_role(role : Role) : String
        role.to_s.downcase
      end

      # gpustack/models.rb: the model list lives at `models` and returns a GPUStack
      # `{ "items": [...] }` payload (not OpenAI's `{ "data": [...] }`). Each item is a
      # GPUStack model record (name / created_at / meta / categories / ...).
      #
      # Divergences:
      # - response.body is a raw String (Crest); JSON.parse here.
      # - Time.parse(created_at) -> Model::Info.to_time (handles the wire formats).
      # - context_window / max_output_tokens come from meta.n_ctx.
      # - capabilities / modalities are derived from categories + meta flags.
      def parse_list_models_response(response : Crest::Response, slug : String,
                                     capabilities : CrystalLLM::Capabilities.class) : Array(Model::Info)
        body = response.body
        return [] of Model::Info if body.empty?

        data = JSON.parse(body)
        items = data["items"]?.try(&.as_a?) || [] of JSON::Any

        items.compact_map do |item_any|
          model = item_any.as_h? || next
          name = model["name"]?.try(&.as_s?) || next

          n_ctx = meta_int(model, "n_ctx")

          Model::Info.build(
            id: name,
            name: name,
            provider: slug,
            family: "gpustack",
            created_at: Model::Info.to_time(model["created_at"]?),
            context_window: n_ctx,
            max_output_tokens: n_ctx,
            capabilities: build_capabilities(model),
            modalities: build_modalities(model),
            metadata: build_metadata(model),
          )
        end
      end

      private def build_metadata(model : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        {
          "description"               => model["description"]? || JSON::Any.new(nil),
          "source"                    => model["source"]? || JSON::Any.new(nil),
          "huggingface_repo_id"       => model["huggingface_repo_id"]? || JSON::Any.new(nil),
          "ollama_library_model_name" => model["ollama_library_model_name"]? || JSON::Any.new(nil),
          "backend"                   => model["backend"]? || JSON::Any.new(nil),
          "meta"                      => model["meta"]? || JSON::Any.new(nil),
          "categories"                => model["categories"]? || JSON::Any.new(nil),
        } of String => JSON::Any
      end

      # gpustack/models.rb#build_capabilities.
      private def build_capabilities(model : Hash(String, JSON::Any)) : Array(String)
        caps = [] of String
        llm = categories_include?(model, "llm")

        caps << "streaming" if llm
        caps << "function_calling" if meta_flag?(model, "support_tool_calls")
        caps << "vision" if meta_flag?(model, "support_vision")
        caps << "reasoning" if meta_flag?(model, "support_reasoning")
        if llm
          caps << "structured_output"
          caps << "json_mode"
        end
        caps
      end

      # gpustack/models.rb#build_modalities.
      private def build_modalities(model : Hash(String, JSON::Any)) : Model::Modalities
        input = [] of String
        output = [] of String

        if categories_include?(model, "llm")
          input << "text"
          input << "image" if meta_flag?(model, "support_vision")
          input << "audio" if meta_flag?(model, "support_audio")
          output << "text"
        elsif categories_include?(model, "embedding")
          input << "text"
          output << "embeddings"
        end

        Model::Modalities.new(input: input, output: output)
      end

      private def categories_include?(model : Hash(String, JSON::Any), value : String) : Bool
        cats = model["categories"]?.try(&.as_a?)
        return false unless cats
        cats.any? { |cat| cat.as_s? == value }
      end

      # Reads a boolean flag out of model["meta"] (truthy by Ruby semantics: a present,
      # non-false, non-null value).
      private def meta_flag?(model : Hash(String, JSON::Any), key : String) : Bool
        meta = model["meta"]?.try(&.as_h?)
        return false unless meta
        value = meta[key]?
        return false if value.nil?
        case raw = value.raw
        when Bool then raw
        when Nil  then false
        else           true
        end
      end

      private def meta_int(model : Hash(String, JSON::Any), key : String) : Int32?
        meta = model["meta"]?.try(&.as_h?)
        return nil unless meta
        value = meta[key]?
        return nil if value.nil?
        case raw = value.raw
        when Int64   then raw.to_i32
        when Int32   then raw
        when Float64 then raw.to_i32
        else              nil
        end
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

      # gpustack/capabilities.rb. Both checks return false (GPUStack does not support
      # per-request tool_choice or parallel-tool-call control). Modelled as a
      # CrystalLLM::Capabilities subclass so it can be passed around as a class (the
      # Crystal port's Capabilities-as-class-hierarchy convention).
      class Capabilities < CrystalLLM::Capabilities
        def self.supports_tool_choice?(model_id : String) : Bool
          false
        end

        def self.supports_tool_parallel_control?(model_id : String) : Bool
          false
        end
      end
    end
  end
end

# Register the provider (ruby_llm: `RubyLLM::Provider.register('gpustack', ...)`).
CrystalLLM::Provider.register("gpustack", CrystalLLM::Providers::GPUStack)

require "./gpustack/embeddings"
