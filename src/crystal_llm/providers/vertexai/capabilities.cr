# ported from lib/ruby_llm/providers/gemini/capabilities.rb @ ruby_llm 1.15.0
#   (Gemini wire format, used by VertexAI — see providers/vertexai.cr header)
#
# Provider-level capability checks + narrow pricing fallbacks (used by
# parse_list_models_response when the API omits limits/pricing).
#
# Divergences:
# - ruby_llm's `Capabilities` is a `module_function` module; the Crystal port is a
#   `CrystalLLM::Capabilities` subclass (so `capabilities` is passed around as a class —
#   see provider_completion.cr).
# - `PRICES` symbol-keyed hash -> a String-keyed lookup built in `family_prices`.
# - `pricing_for` returns the wire Hash(String, JSON::Any) shape Model::Pricing consumes.
# - imagen `price`-only family -> {price, price} input/output (image pricing not special-cased).
require "json"
require "../vertexai"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      # Vertex AI / Gemini capability + pricing helper (see file header).
      class Capabilities < CrystalLLM::Capabilities
        def self.context_window_for(model_id : String) : Int32?
          case model_id
          when .matches?(/gemini-2\.5-pro-exp-03-25/), .matches?(/gemini-2\.0-flash/),
               .matches?(/gemini-2\.0-flash-lite/), .matches?(/gemini-1\.5-flash/),
               .matches?(/gemini-1\.5-flash-8b/)
            1_048_576
          when .matches?(/gemini-1\.5-pro/)                                then 2_097_152
          when .matches?(/gemini-embedding-exp/)                           then 8_192
          when .matches?(/text-embedding-004/), .matches?(/embedding-001/) then 2_048
          when .matches?(/aqa/)                                            then 7_168
          when .matches?(/imagen-3/)                                       then nil
          else                                                                  32_768
          end
        end

        def self.max_tokens_for(model_id : String) : Int32?
          case model_id
          when .matches?(/gemini-2\.5-pro-exp-03-25/) then 64_000
          when .matches?(/gemini-2\.0-flash/), .matches?(/gemini-2\.0-flash-lite/),
               .matches?(/gemini-1\.5-flash/), .matches?(/gemini-1\.5-flash-8b/),
               .matches?(/gemini-1\.5-pro/)
            8_192
          when .matches?(/gemini-embedding-exp/)                           then nil
          when .matches?(/text-embedding-004/), .matches?(/embedding-001/) then 768
          when .matches?(/imagen-3/)                                       then 4
          else                                                                  4_096
          end
        end

        def self.critical_capabilities_for(model_id : String) : Array(String)
          caps = [] of String
          caps << "function_calling" if supports_functions?(model_id)
          caps << "structured_output" if supports_structured_output?(model_id)
          caps << "vision" if supports_vision?(model_id)
          caps
        end

        def self.supports_vision?(model_id : String) : Bool
          return false if model_id.matches?(/text-embedding|embedding-001|aqa/)
          model_id.matches?(/gemini|flash|pro|imagen/)
        end

        def self.supports_functions?(model_id : String) : Bool
          return false if model_id.matches?(/text-embedding|embedding-001|aqa|flash-lite|imagen|gemini-2\.0-flash-lite/)
          model_id.matches?(/gemini|pro|flash/)
        end

        def self.supports_structured_output?(model_id : String) : Bool
          if model_id.matches?(/text-embedding|embedding-001|aqa|imagen|gemini-2\.0-flash-lite|gemini-2\.5-pro-exp-03-25/)
            return false
          end
          model_id.matches?(/gemini|pro|flash/)
        end

        # family => {input_per_million, output_per_million}.
        PRICES = {
          "flash_2"          => {0.10, 0.40},
          "flash_lite_2"     => {0.075, 0.30},
          "flash"            => {0.075, 0.30},
          "flash_8b"         => {0.0375, 0.15},
          "pro"              => {1.25, 5.0},
          "pro_2_5"          => {0.12, 0.50},
          "gemini_embedding" => {0.002, 0.004},
          "embedding"        => {0.0, 0.0},
          "imagen"           => {0.03, 0.03},
          "aqa"              => {0.0, 0.0},
          "base"             => {0.075, 0.30},
        } of String => Tuple(Float64, Float64)

        # ameba:disable Metrics/CyclomaticComplexity
        def self.pricing_family(model_id : String) : String
          case model_id
          when .matches?(/gemini-2\.5-pro-exp-03-25/) then "pro_2_5"
          when .matches?(/gemini-2\.0-flash-lite/)    then "flash_lite_2"
          when .matches?(/gemini-2\.0-flash/)         then "flash_2"
          when .matches?(/gemini-1\.5-flash-8b/)      then "flash_8b"
          when .matches?(/gemini-1\.5-flash/)         then "flash"
          when .matches?(/gemini-1\.5-pro/)           then "pro"
          when .matches?(/gemini-embedding-exp/)      then "gemini_embedding"
          when .matches?(/text-embedding|embedding/)  then "embedding"
          when .matches?(/imagen/)                    then "imagen"
          when .matches?(/aqa/)                       then "aqa"
          else                                             "base"
          end
        end

        # Returns the wire pricing shape (text_tokens/standard) Model::Pricing consumes.
        def self.pricing_for(model_id : String) : Hash(String, JSON::Any)
          prices = PRICES[pricing_family(model_id)]? || {0.075, 0.30}

          standard = {
            "input_per_million"  => JSON::Any.new(prices[0]),
            "output_per_million" => JSON::Any.new(prices[1]),
          } of String => JSON::Any

          {
            "text_tokens" => JSON::Any.new({
              "standard" => JSON::Any.new(standard),
            } of String => JSON::Any),
          } of String => JSON::Any
        end
      end
    end
  end
end
