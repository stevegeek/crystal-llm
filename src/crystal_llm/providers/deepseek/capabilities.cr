# ported from lib/ruby_llm/providers/deepseek/capabilities.rb @ ruby_llm 1.15.0
#
# Provider-level capability checks used outside the model registry. ruby_llm's
# `Capabilities` is a `module_function` module; the Crystal port is a
# `CrystalLLM::Capabilities` subclass (so a provider's `capabilities` can be passed
# around as a class — see provider_completion.cr).
#
# ruby_llm's DeepSeek::Capabilities defines ONLY `supports_tool_choice?` and
# `supports_tool_parallel_control?` (no model-registry pricing/limits helpers — the
# DeepSeek model registry rides on the vendored models.json data, not code). The
# base `CrystalLLM::Capabilities` answers the registry helpers conservatively (nil
# limits / empty pricing), which is the faithful behavior here.
require "../openai"

module CrystalLLM
  module Providers
    class DeepSeek < OpenAI
      # DeepSeek capability helper (see file header).
      class Capabilities < CrystalLLM::Capabilities
        def self.supports_tool_choice?(model_id : String) : Bool
          true
        end

        def self.supports_tool_parallel_control?(model_id : String) : Bool
          false
        end
      end
    end
  end
end
