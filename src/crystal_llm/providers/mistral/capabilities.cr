# ported from lib/ruby_llm/providers/mistral/capabilities.rb @ ruby_llm 1.15.0
#
# Mistral capability + display/metadata helpers used by parse_list_models_response.
#
# Divergences:
# - ruby_llm's `Capabilities` is a `module_function` module; the Crystal port is a
#   `CrystalLLM::Capabilities` subclass (so a provider's `capabilities` can be passed
#   around as a class — see provider_completion.cr).
# - `modalities_for`/`pricing_for` return the wire `Hash(String, JSON::Any)` shapes
#   that Model::Modalities / Model::Pricing consume.
# - ruby_llm's `capabilities_for` is exposed here as `critical_capabilities_for` to
#   match the OpenAI port's hook name used by `parse_list_models_response`; the
#   full ruby `capabilities_for` logic (streaming/batch/fine_tuning/etc.) is ported.
require "json"
require "../mistral"

module CrystalLLM
  module Providers
    class Mistral < OpenAI
      # Mistral capability helper (see file header for divergences).
      class Capabilities < CrystalLLM::Capabilities
        def self.supports_streaming?(model_id : String) : Bool
          !model_id.matches?(/embed|moderation|ocr|transcriptions/)
        end

        def self.supports_tools?(model_id : String) : Bool
          !model_id.matches?(/embed|moderation|ocr|voxtral|transcriptions|mistral-(tiny|small)-(2312|2402)/)
        end

        def self.supports_tool_choice?(_model_id : String) : Bool
          true
        end

        def self.supports_tool_parallel_control?(_model_id : String) : Bool
          true
        end

        def self.supports_vision?(model_id : String) : Bool
          model_id.matches?(/pixtral|mistral-small-(2503|2506)|mistral-medium/)
        end

        def self.supports_json_mode?(model_id : String) : Bool
          !model_id.matches?(/embed|moderation|ocr|voxtral|transcriptions/) && supports_tools?(model_id)
        end

        def self.supports_reasoning?(model_id : String) : Bool
          model_id.matches?(/magistral/) ||
            model_id.matches?(/\Amistral-(?:small-latest|medium-(?:3(?:[.-]5)?|latest))\z/)
        end

        # ameba:disable Metrics/CyclomaticComplexity
        def self.format_display_name(model_id : String) : String
          case model_id
          when .matches?(/mistral-large/)      then "Mistral Large"
          when .matches?(/mistral-medium/)     then "Mistral Medium"
          when .matches?(/mistral-small/)      then "Mistral Small"
          when .matches?(/ministral-3b/)       then "Ministral 3B"
          when .matches?(/ministral-8b/)       then "Ministral 8B"
          when .matches?(/codestral/)          then "Codestral"
          when .matches?(/pixtral-large/)      then "Pixtral Large"
          when .matches?(/pixtral-12b/)        then "Pixtral 12B"
          when .matches?(/mistral-embed/)      then "Mistral Embed"
          when .matches?(/mistral-moderation/) then "Mistral Moderation"
          else
            model_id.split("-").map(&.capitalize).join(" ")
          end
        end

        def self.model_family(model_id : String) : String
          case model_id
          when .matches?(/mistral-large/)      then "mistral-large"
          when .matches?(/mistral-medium/)     then "mistral-medium"
          when .matches?(/mistral-small/)      then "mistral-small"
          when .matches?(/ministral/)          then "ministral"
          when .matches?(/codestral/)          then "codestral"
          when .matches?(/pixtral/)            then "pixtral"
          when .matches?(/mistral-embed/)      then "mistral-embed"
          when .matches?(/mistral-moderation/) then "mistral-moderation"
          else
            "mistral"
          end
        end

        def self.context_window_for(_model_id : String) : Int32?
          32_768
        end

        def self.max_tokens_for(_model_id : String) : Int32?
          8192
        end

        # Wire modalities shape consumed by Model::Modalities.
        def self.modalities_for(model_id : String) : Hash(String, JSON::Any)
          input, output =
            if model_id.matches?(/pixtral/)
              {["text", "image"], ["text"]}
            elsif model_id.matches?(/embed/)
              {["text"], ["embeddings"]}
            else
              {["text"], ["text"]}
            end

          {
            "input"  => JSON::Any.new(input.map { |modality| JSON::Any.new(modality) }),
            "output" => JSON::Any.new(output.map { |modality| JSON::Any.new(modality) }),
          } of String => JSON::Any
        end

        # ameba:disable Metrics/CyclomaticComplexity
        def self.capabilities_for(model_id : String) : Array(String)
          case model_id
          when .matches?(/moderation/)          then return ["moderation"]
          when .matches?(/voxtral.*transcribe/) then return ["transcription"]
          when .matches?(/ocr/)                 then return ["vision"]
          end

          caps = [] of String
          caps << "streaming" if supports_streaming?(model_id)
          caps << "function_calling" if supports_tools?(model_id)
          caps << "structured_output" if supports_json_mode?(model_id)
          caps << "vision" if supports_vision?(model_id)
          caps << "reasoning" if supports_reasoning?(model_id)
          caps << "batch" unless model_id.matches?(/voxtral|ocr|embed|moderation/)
          caps << "fine_tuning" if model_id.matches?(/mistral-(small|medium|large)|devstral/)
          caps << "distillation" if model_id.matches?(/ministral/)
          caps << "predicted_outputs" if model_id.matches?(/codestral/)

          caps.uniq
        end

        # The OpenAI-port hook name used by parse_list_models_response.
        def self.critical_capabilities_for(model_id : String) : Array(String)
          capabilities_for(model_id)
        end

        # Wire pricing shape consumed by Model::Pricing. ruby_llm returns flat
        # zeros ({input: 0.0, output: 0.0}); the port nests them under the
        # text_tokens/standard tiers Model::Pricing expects. NOTE: Model::Pricing
        # treats an all-zero tier as empty (faithful to ruby_llm), so the resulting
        # Pricing reports nil text-token prices — the zeros are placeholders.
        def self.pricing_for(_model_id : String) : Hash(String, JSON::Any)
          {
            "text_tokens" => JSON::Any.new({
              "standard" => JSON::Any.new({
                "input_per_million"  => JSON::Any.new(0.0),
                "output_per_million" => JSON::Any.new(0.0),
              } of String => JSON::Any),
            } of String => JSON::Any),
          } of String => JSON::Any
        end

        # ameba:disable Metrics/CyclomaticComplexity
        def self.release_date_for(model_id : String) : String?
          case model_id
          when "open-mistral-7b", "mistral-tiny"
            "2023-09-27"
          when "mistral-medium-2312", "mistral-small-2312", "mistral-small",
               "open-mixtral-8x7b", "mistral-tiny-2312"
            "2023-12-11"
          when "mistral-embed"
            "2024-01-11"
          when "mistral-large-2402", "mistral-small-2402"
            "2024-02-26"
          when "open-mixtral-8x22b", "open-mixtral-8x22b-2404"
            "2024-04-17"
          when "codestral-2405"
            "2024-05-22"
          when "codestral-mamba-2407", "codestral-mamba-latest", "open-codestral-mamba"
            "2024-07-16"
          when "open-mistral-nemo", "open-mistral-nemo-2407", "mistral-tiny-2407",
               "mistral-tiny-latest"
            "2024-07-18"
          when "mistral-large-2407"
            "2024-07-24"
          when "pixtral-12b-2409", "pixtral-12b-latest", "pixtral-12b"
            "2024-09-17"
          when "mistral-small-2409"
            "2024-09-18"
          when "ministral-3b-2410", "ministral-3b-latest", "ministral-8b-2410",
               "ministral-8b-latest"
            "2024-10-16"
          when "pixtral-large-2411", "pixtral-large-latest", "mistral-large-pixtral-2411"
            "2024-11-12"
          when "mistral-large-2411", "mistral-large-latest", "mistral-large"
            "2024-11-20"
          when "codestral-2411-rc5", "mistral-moderation-2411", "mistral-moderation-latest"
            "2024-11-26"
          when "codestral-2412"
            "2024-12-17"
          when "mistral-small-2501"
            "2025-01-13"
          when "codestral-2501"
            "2025-01-14"
          when "mistral-saba-2502", "mistral-saba-latest"
            "2025-02-18"
          when "mistral-small-2503"
            "2025-03-03"
          when "mistral-ocr-2503"
            "2025-03-21"
          when "mistral-medium", "mistral-medium-latest", "mistral-medium-2505"
            "2025-05-06"
          when "codestral-embed", "codestral-embed-2505"
            "2025-05-21"
          when "mistral-ocr-2505", "mistral-ocr-latest"
            "2025-05-23"
          when "devstral-small-2505"
            "2025-05-28"
          when "mistral-small-2506", "mistral-small-latest", "magistral-medium-2506",
               "magistral-medium-latest"
            "2025-06-10"
          when "devstral-small-2507", "devstral-small-latest", "devstral-medium-2507",
               "devstral-medium-latest"
            "2025-07-09"
          when "codestral-2508", "codestral-latest"
            "2025-08-30"
          end
        end
      end
    end
  end
end
