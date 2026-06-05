# ported from lib/ruby_llm/providers/gpustack/models.rb @ ruby_llm 1.15.0
#
# Models methods of the GPUStack API integration. The model list lives at `models`
# and returns a GPUStack `{ "items": [...] }` payload (not OpenAI's `{ "data": [...] }`).
# Each item is a GPUStack model record (name / created_at / meta / categories / ...).
#
# Divergences from ruby_llm:
# - response.body is a raw String (Crest); JSON.parse here.
# - Time.parse(created_at) -> Model::Info.to_time (handles the wire formats).
# - context_window / max_output_tokens come from meta.n_ctx.
# - capabilities / modalities are derived from categories + meta flags.
# - models_url is "models" (same as OpenAI's), so it is inherited and not redefined.
require "json"
require "../gpustack"

module CrystalLLM
  module Providers
    class GPUStack < OpenAI
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
    end
  end
end
