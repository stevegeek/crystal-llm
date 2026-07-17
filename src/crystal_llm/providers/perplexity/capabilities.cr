# ported from lib/ruby_llm/providers/perplexity/capabilities.rb @ ruby_llm 1.16.0
#
# Provider-level capability checks and narrow registry fallbacks (used by
# `parse_list_models_response`).
#
# Divergences (mirroring the OpenAI::Capabilities porting decisions):
# - ruby_llm's `Capabilities` is a `module_function` module; the Crystal port is a
#   `CrystalLLM::Capabilities` subclass (so a provider's `capabilities` can be passed
#   around as a class — see provider_completion.cr).
# - `PRICES` symbol-keyed family hashes -> a String-keyed lookup. The optional
#   `reasoning_output` entry (sonar-deep-research) becomes an extra tuple slot.
# - `pricing_for` returns the wire `Hash(String, JSON::Any)` shape Model::Pricing
#   consumes (`{"text_tokens" => {"standard" => {"input_per_million" => ...}}}`),
#   adding `reasoning_output_per_million` only when the family defines it.
# - `supports_tool_choice?` / `supports_tool_parallel_control?` are ported as class
#   methods (always false for Perplexity); they're not on the base Capabilities
#   surface yet (tool_prefs is deferred — see provider_completion.cr) but are kept
#   here for when the chat/agent layer wires tool prefs back in.
require "json"
require "../perplexity"

module CrystalLLM
  module Providers
    class Perplexity < OpenAI
      # Perplexity capability + narrow-pricing helper (see file header for divergences).
      class Capabilities < CrystalLLM::Capabilities
        # family => {input, output, reasoning_output?} (per-million). The unknown
        # family falls back to {1.0, 1.0, nil} (ruby_llm's PRICES.fetch default).
        PRICES = {
          "sonar"               => {1.0, 1.0, nil},
          "sonar_pro"           => {3.0, 15.0, nil},
          "sonar_reasoning"     => {1.0, 5.0, nil},
          "sonar_reasoning_pro" => {2.0, 8.0, nil},
          "sonar_deep_research" => {2.0, 8.0, 3.0},
        } of String => Tuple(Float64, Float64, Float64?)

        def self.supports_tool_choice?(model_id : String) : Bool
          false
        end

        def self.supports_tool_parallel_control?(model_id : String) : Bool
          false
        end

        def self.context_window_for(model_id : String) : Int32?
          model_id.matches?(/sonar-pro/) ? 200_000 : 128_000
        end

        def self.max_tokens_for(model_id : String) : Int32?
          model_id.matches?(/sonar-(?:pro|reasoning-pro)/) ? 8_192 : 4_096
        end

        def self.critical_capabilities_for(model_id : String) : Array(String)
          caps = [] of String
          caps << "vision" if model_id.matches?(/sonar(?:-pro|-reasoning(?:-pro)?)?$/)
          caps << "reasoning" if model_id.matches?(/reasoning|deep-research/)
          caps
        end

        def self.model_family(model_id : String) : String
          case model_id
          when "sonar"               then "sonar"
          when "sonar-pro"           then "sonar_pro"
          when "sonar-reasoning"     then "sonar_reasoning"
          when "sonar-reasoning-pro" then "sonar_reasoning_pro"
          when "sonar-deep-research" then "sonar_deep_research"
          else                            "unknown"
          end
        end

        # Returns the wire pricing shape (text_tokens/standard) Model::Pricing consumes.
        def self.pricing_for(model_id : String) : Hash(String, JSON::Any)
          prices = PRICES[model_family(model_id)]? || {1.0, 1.0, nil}

          standard = {
            "input_per_million"  => JSON::Any.new(prices[0]),
            "output_per_million" => JSON::Any.new(prices[1]),
          } of String => JSON::Any

          if reasoning = prices[2]
            standard["reasoning_output_per_million"] = JSON::Any.new(reasoning)
          end

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
