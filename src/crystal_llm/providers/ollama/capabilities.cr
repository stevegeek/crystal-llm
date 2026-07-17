# ported from lib/ruby_llm/providers/ollama/capabilities.rb @ ruby_llm 1.16.0
#
# Determines capabilities for Ollama models.
#
# Divergences:
# - ruby_llm's `Capabilities` is a `module_function` module; the Crystal port is a
#   `CrystalLLM::Capabilities` subclass (so a provider's `capabilities` can be passed
#   around as a class — see provider_completion.cr). It subclasses the conservative
#   BASE (not OpenAI's), matching ollama.rb: the Ollama models parser hardcodes
#   modalities/capabilities/pricing and never routes through this helper's
#   context_window/pricing methods, so the base defaults (nil/empty) are correct.
# - `supports_tool_choice?` / `supports_tool_parallel_control?` (both false) are part
#   of the tool_prefs surface, which the Crystal port defers (see
#   provider_completion.cr). They are ported here for when the chat/agent layer wires
#   tool_prefs back in; until then nothing in the chat pipeline calls them.
require "json"
require "../ollama"

module CrystalLLM
  module Providers
    class Ollama < OpenAI
      # Ollama capability helper (see file header for divergences).
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
