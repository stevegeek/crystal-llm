# ported from lib/ruby_llm/model/modalities.rb @ ruby_llm 1.16.0
require "json"

module CrystalLLM
  module Model
    # Holds and manages input and output modalities for a language model.
    #
    # In ruby_llm `data` is a (symbol-keyed) Hash whose `:input`/`:output` values
    # are run through `Array(...).map(&:to_s)` — `nil` becomes `[]`, a scalar
    # becomes a one-element array, and an array is mapped to strings. The
    # registry data arrives as parsed JSON, so the primary constructor takes a
    # `Hash(String, JSON::Any)` (string keys, JSON values) and reproduces that
    # `Array(...)` coercion. A typed convenience constructor is also provided for
    # callers that already hold `Array(String)` (divergence: extra overload, no
    # behaviour change).
    class Modalities
      getter input : Array(String)
      getter output : Array(String)

      def initialize(data : Hash(String, JSON::Any))
        @input = coerce(data["input"]?)
        @output = coerce(data["output"]?)
      end

      def initialize(input : Array(String) = [] of String, output : Array(String) = [] of String)
        @input = input
        @output = output
      end

      def to_h : Hash(Symbol, Array(String))
        {
          :input  => input,
          :output => output,
        }
      end

      # Mirrors Ruby's `Array(value).map(&:to_s)`: nil/null -> [], a JSON array ->
      # its elements stringified, any scalar -> a single stringified element.
      private def coerce(value : JSON::Any?) : Array(String)
        return [] of String if value.nil?

        raw = value.raw
        case raw
        when Nil
          [] of String
        when Array
          raw.map { |element| stringify(element) }
        else
          [stringify(value)]
        end
      end

      private def stringify(value : JSON::Any) : String
        raw = value.raw
        raw.is_a?(String) ? raw : raw.to_s
      end
    end
  end
end
