# ported from lib/ruby_llm/providers/openai/temperature.rb @ ruby_llm 1.15.0
require "../openai"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      # Normalizes temperature for OpenAI models with provider-specific requirements.
      module Temperature
        extend self

        # o-series + gpt-5 require temperature=1.0; `-search` models reject the
        # parameter entirely (return nil to omit it).
        def normalize(temperature : Float64?, model_id : String) : Float64?
          if model_id.matches?(/^(o\d|gpt-5)/) && !temperature.nil? && !temperature_close_to_one?(temperature)
            1.0
          elsif model_id.includes?("-search")
            nil
          else
            temperature
          end
        end

        def temperature_close_to_one?(temperature : Float64) : Bool
          (temperature - 1.0).abs <= Float64::EPSILON
        end
      end
    end
  end
end
