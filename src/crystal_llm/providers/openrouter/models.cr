# ported from lib/ruby_llm/providers/openrouter/models.rb @ ruby_llm 1.15.0
#
# OpenRouter's `/models` returns a much richer per-model record than OpenAI's
# (architecture input/output modalities, per-million pricing, supported_parameters,
# top_provider limits). Capabilities are derived from the provider-supplied
# `supported_parameters` list (see #supported_parameters_to_capabilities) rather than
# from a model-id pattern table — mirroring ruby_llm's openrouter/models.rb, which
# defines that helper privately on the Models mixin (NOT a Capabilities class).
#
# Divergences from ruby_llm's openrouter/models.rb:
# - `response.body` is a raw String (Crest); JSON.parse it here.
# - `Time.at(created)` -> `Time.unix(created)`.
# - pricing values arrive as strings in the OpenRouter wire ("0.0000015"); ruby_llm
#   does `value.to_f` then `* 1_000_000`. The port coerces String/numeric JSON to
#   Float64 the same way and only keeps positive prices.
# - Model::Info is built via `.build`; modalities/pricing/metadata are wrapped in
#   their typed values (Modalities/Pricing take a wire `Hash(String, JSON::Any)`).
# - the unused `_capabilities` argument in ruby_llm becomes the pipeline's
#   `capabilities` param (Capabilities class); OpenRouter ignores it (provider data
#   drives capabilities), matching ruby_llm.
require "json"
require "../openai"
require "../openrouter"

module CrystalLLM
  module Providers
    class OpenRouter < OpenAI
      def models_url : String
        "models"
      end

      def parse_list_models_response(response : Crest::Response, slug : String,
                                     capabilities : CrystalLLM::Capabilities.class) : Array(Model::Info)
        body = response.body
        return [] of Model::Info if body.empty?

        data = JSON.parse(body)
        rows = data["data"]?.try(&.as_a?) || [] of JSON::Any

        rows.compact_map do |row_any|
          row = row_any.as_h? || next
          model_id = row["id"]?.try(&.as_s?) || next

          modalities = build_modalities(row)
          pricing = build_pricing(row)
          caps = supported_parameters_to_capabilities(row["supported_parameters"]?)

          created_at = nil
          if created = row["created"]?
            if epoch = created.as_i64?
              created_at = Time.unix(epoch)
            end
          end

          Model::Info.build(
            id: model_id,
            name: row["name"]?.try(&.as_s?) || model_id,
            provider: slug,
            family: model_id.split('/').first?,
            created_at: created_at,
            context_window: int_or_nil(row["context_length"]?),
            max_output_tokens: int_or_nil(row.dig?("top_provider", "max_completion_tokens")),
            modalities: modalities,
            capabilities: caps,
            pricing: pricing,
            metadata: build_metadata(row)
          )
        end
      end

      # Maps an OpenRouter `supported_parameters` list to CrystalLLM capability
      # strings. `streaming` is always present; the rest gate on specific params.
      # Mirrors ruby_llm openrouter/models.rb#supported_parameters_to_capabilities
      # (a private Models helper, not a separate Capabilities class).
      private def supported_parameters_to_capabilities(params : JSON::Any?) : Array(String)
        list = params.try(&.as_a?)
        return [] of String if list.nil?

        names = list.compact_map(&.as_s?)
        capabilities = [] of String
        capabilities << "streaming"
        if names.includes?("tools") || names.includes?("tool_choice")
          capabilities << "function_calling"
        end
        capabilities << "structured_output" if names.includes?("response_format")
        capabilities << "batch" if names.includes?("batch")
        if names.includes?("logit_bias") && names.includes?("top_k")
          capabilities << "predicted_outputs"
        end
        capabilities
      end

      private def build_modalities(row : Hash(String, JSON::Any)) : Model::Modalities
        Model::Modalities.new(
          input: string_array(row.dig?("architecture", "input_modalities")),
          output: string_array(row.dig?("architecture", "output_modalities"))
        )
      end

      # OpenRouter pricing wire keys -> the Model::Pricing standard text_tokens keys.
      private def build_pricing(row : Hash(String, JSON::Any)) : Model::Pricing
        standard = {} of String => JSON::Any
        mapping = {
          "prompt"             => "input_per_million",
          "completion"         => "output_per_million",
          "input_cache_read"   => "cache_read_input_per_million",
          "internal_reasoning" => "reasoning_output_per_million",
        }

        mapping.each do |source_key, target_key|
          value = float_or_zero(row.dig?("pricing", source_key))
          standard[target_key] = JSON::Any.new(value * 1_000_000) if value > 0
        end

        data = {
          "text_tokens" => JSON::Any.new({
            "standard" => JSON::Any.new(standard),
          } of String => JSON::Any),
        } of String => JSON::Any

        Model::Pricing.new(data)
      end

      private def build_metadata(row : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        {
          "description"          => row["description"]? || JSON::Any.new(nil),
          "architecture"         => row["architecture"]? || JSON::Any.new(nil),
          "top_provider"         => row["top_provider"]? || JSON::Any.new(nil),
          "per_request_limits"   => row["per_request_limits"]? || JSON::Any.new(nil),
          "supported_parameters" => row["supported_parameters"]? || JSON::Any.new(nil),
        } of String => JSON::Any
      end

      private def string_array(value : JSON::Any?) : Array(String)
        arr = value.try(&.as_a?)
        return [] of String if arr.nil?
        arr.compact_map(&.as_s?)
      end

      private def int_or_nil(value : JSON::Any?) : Int32?
        return nil if value.nil?
        case raw = value.raw
        when Int64   then raw.to_i32
        when Int32   then raw
        when Float64 then raw.to_i32
        else              nil
        end
      end

      # OpenRouter prices arrive as strings ("0.0000015"); coerce String/numeric to
      # Float64 (ruby_llm's `value.to_s.to_f`), defaulting non-numeric/nil to 0.
      private def float_or_zero(value : JSON::Any?) : Float64
        return 0.0 if value.nil?
        case raw = value.raw
        when Float64 then raw
        when Int64   then raw.to_f
        when Int32   then raw.to_f
        when String  then raw.to_f? || 0.0
        else              0.0
        end
      end
    end
  end
end
