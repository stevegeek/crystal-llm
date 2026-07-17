# ported from lib/ruby_llm/providers/anthropic/capabilities.rb @ ruby_llm 1.16.0
#
# Provider-level capability checks used outside the model registry.
#
# Divergence: ruby_llm's `Capabilities` is a `module_function` module; the Crystal
# port is a `CrystalLLM::Capabilities` subclass (so a provider's `capabilities` can be
# passed around as a class — see provider_completion.cr). Anthropic upstream only
# defines two provider-level predicates (both unconditionally true); the registry-data
# helpers (context_window_for/max_tokens_for/pricing_for) inherit the conservative
# base (nil/empty) — Anthropic ships those via the vendored models.json, not code.
require "json"
require "../anthropic"

module CrystalLLM
  module Providers
    class Anthropic < Provider
      # Anthropic provider-level capability helper (see file header for divergences).
      class Capabilities < CrystalLLM::Capabilities
        def self.supports_tool_choice?(model_id : String) : Bool
          true
        end

        def self.supports_tool_parallel_control?(model_id : String) : Bool
          true
        end
      end
    end
  end
end
