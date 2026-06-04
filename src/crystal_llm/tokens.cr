# ported from lib/ruby_llm/tokens.rb @ ruby_llm 1.15.0
module CrystalLLM
  # Token usage for a response.
  class Tokens
    getter input : Int32?
    getter output : Int32?
    getter cached : Int32?
    getter cache_creation : Int32?
    getter thinking : Int32?

    def initialize(@input : Int32? = nil, @output : Int32? = nil, @cached : Int32? = nil,
                   @cache_creation : Int32? = nil, thinking : Int32? = nil, reasoning : Int32? = nil)
      @thinking = thinking || reasoning
    end

    # Returns nil when every bucket is nil (mirrors ruby_llm's `Tokens.build`).
    def self.build(input : Int32? = nil, output : Int32? = nil, cached : Int32? = nil,
                   cache_creation : Int32? = nil, thinking : Int32? = nil, reasoning : Int32? = nil) : Tokens?
      return nil if {input, output, cached, cache_creation, thinking, reasoning}.all?(Nil)

      new(input, output, cached, cache_creation, thinking, reasoning)
    end

    def to_h : Hash(Symbol, Int32)
      h = {} of Symbol => Int32
      if v = input
        h[:input_tokens] = v
      end
      if v = output
        h[:output_tokens] = v
      end
      if v = cached
        h[:cached_tokens] = v
      end
      if v = cache_creation
        h[:cache_creation_tokens] = v
      end
      if v = thinking
        h[:thinking_tokens] = v
      end
      h
    end

    def reasoning : Int32?
      thinking
    end

    def cache_read : Int32?
      cached
    end

    def cache_write : Int32?
      cache_creation
    end
  end
end
