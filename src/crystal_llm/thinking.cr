# ported from lib/ruby_llm/thinking.rb @ ruby_llm 1.15.0
module CrystalLLM
  # Represents provider thinking output.
  class Thinking
    getter text : String?
    getter signature : String?

    def initialize(text : String? = nil, signature : String? = nil)
      @text = text
      @signature = signature
    end

    # Returns nil when both text and signature are blank (mirrors ruby_llm's
    # `Thinking.build`, where empty strings are treated as nil).
    def self.build(text : String? = nil, signature : String? = nil) : Thinking?
      text = nil if text.is_a?(String) && text.empty?
      signature = nil if signature.is_a?(String) && signature.empty?

      return nil if text.nil? && signature.nil?

      new(text: text, signature: signature)
    end

    # ruby_llm overrides `pretty_print` to redact the signature. Crystal's
    # equivalent inspection hook is `inspect`; we redact the signature there.
    def inspect(io : IO) : Nil
      io << "#<" << self.class.name
      io << " text="
      @text.inspect(io)
      io << ", signature="
      (@signature ? "[REDACTED]" : nil).inspect(io)
      io << '>'
    end

    # Normalized config for thinking across providers.
    class Config
      getter effort : String?
      getter budget : Int32?

      # ruby_llm accepts a Symbol or String for `effort` and stringifies symbols;
      # symbols-as-runtime-data become String here (design §11), so effort is a String.
      def initialize(effort : String? = nil, budget : Int32? = nil)
        @effort = effort
        @budget = budget
      end

      def enabled? : Bool
        !effort.nil? || !budget.nil?
      end
    end
  end
end
