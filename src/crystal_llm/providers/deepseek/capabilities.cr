# ported from lib/ruby_llm/providers/deepseek/capabilities.rb @ ruby_llm 1.16.0
#
# Provider-level capability checks used outside the model registry. ruby_llm's
# `Capabilities` is a `module_function` module; the Crystal port is a
# `CrystalLLM::Capabilities` subclass (so a provider's `capabilities` can be passed
# around as a class — see provider_completion.cr).
#
# ruby_llm 3f27b864 adds context_window_for/max_tokens_for/critical_capabilities_for/
# pricing_for — narrow fallbacks for a live `list_models` response that doesn't carry
# limits/pricing (the DeepSeek registry mostly rides on the vendored models.json
# data, but these back-fill when models.dev/provider data is blank).
# - `pricing_for` returns the wire `Hash(String, JSON::Any)` shape Model::Pricing
#   consumes (`{"text_tokens" => {"standard" => {"input_per_million" => ...}}}`).
require "json"
require "../openai"

module CrystalLLM
  module Providers
    class DeepSeek < OpenAI
      # DeepSeek capability helper (see file header).
      class Capabilities < CrystalLLM::Capabilities
        DEFAULT_CONTEXT_WINDOW    = 1_000_000
        DEFAULT_MAX_OUTPUT_TOKENS =   384_000

        # family => {input, output, cache_read} per-million.
        DEFAULT_PRICES = {input: 0.14, output: 0.28, cache_read: 0.0028}
        PRO_PRICES     = {input: 0.435, output: 0.87, cache_read: 0.003625}

        def self.supports_tool_choice?(model_id : String) : Bool
          true
        end

        def self.supports_tool_parallel_control?(model_id : String) : Bool
          false
        end

        def self.context_window_for(model_id : String) : Int32?
          DEFAULT_CONTEXT_WINDOW
        end

        def self.max_tokens_for(model_id : String) : Int32?
          DEFAULT_MAX_OUTPUT_TOKENS
        end

        def self.critical_capabilities_for(model_id : String) : Array(String)
          v4_model = model_id.starts_with?("deepseek-v4-")
          capabilities = ["function_calling"]
          capabilities << "structured_output" if v4_model
          capabilities << "reasoning" if model_id == "deepseek-reasoner" || v4_model
          capabilities
        end

        def self.pricing_for(model_id : String) : Hash(String, JSON::Any)
          prices = model_id == "deepseek-v4-pro" ? PRO_PRICES : DEFAULT_PRICES

          standard = {
            "input_per_million"            => JSON::Any.new(prices[:input]),
            "output_per_million"           => JSON::Any.new(prices[:output]),
            "cache_read_input_per_million" => JSON::Any.new(prices[:cache_read]),
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
