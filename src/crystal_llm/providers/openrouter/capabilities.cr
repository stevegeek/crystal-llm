# ported from lib/ruby_llm/providers/openrouter/models.rb @ ruby_llm 1.15.0
#   (the supported_parameters_to_capabilities helper)
#
# OpenRouter derives a model's capability list from the provider-supplied
# `supported_parameters` array, NOT from a model-id pattern/price table (unlike
# OpenAI's Capabilities). So this Capabilities subclass keeps the conservative base
# context/limit/pricing answers (provider data drives those in models.cr) and only
# adds the `supported_parameters_to_capabilities` mapping used by
# parse_list_models_response.
require "json"
require "../openai"
require "../openrouter"

module CrystalLLM
  module Providers
    class OpenRouter < OpenAI
      # OpenRouter capability helper. Capabilities come from each model's
      # `supported_parameters` (see supported_parameters_to_capabilities); the
      # id-pattern context/limit/pricing answers fall through to the base.
      class Capabilities < CrystalLLM::Capabilities
        # Maps an OpenRouter `supported_parameters` list to CrystalLLM capability
        # strings. `streaming` is always present; the rest gate on specific params.
        def self.supported_parameters_to_capabilities(params : JSON::Any?) : Array(String)
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
      end
    end
  end
end
