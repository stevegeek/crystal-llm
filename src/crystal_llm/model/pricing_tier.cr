# ported from lib/ruby_llm/model/pricing_tier.rb @ ruby_llm 1.15.0
module CrystalLLM
  module Model
    # Stores non-zero pricing values for a single pricing tier.
    #
    # Divergences from ruby_llm:
    # - ruby_llm declares its 7 attributes as symbols in `ATTRIBUTES` and uses
    #   `define_method` to generate readers/writers and a symbol-keyed `[]`.
    #   Crystal has no runtime symbols-as-data / metaprogramming (PORTING.md / design §11),
    #   so the attribute set is modelled as the `Attribute` enum and the accessors are
    #   written out explicitly. `[]` accepts the enum (and a String/Symbol form mirroring
    #   ruby_llm's `key.to_sym`).
    # - Internal storage and `to_h` are keyed by `Attribute` rather than Ruby symbols.
    #   Values are `Float64` (pricing is always numeric); ruby_llm stores whatever truthy,
    #   non-zero value it is handed.
    class PricingTier
      # The fixed set of pricing fields (ruby_llm's `ATTRIBUTES`).
      enum Attribute
        InputPerMillion
        OutputPerMillion
        CacheReadInputPerMillion
        CacheWriteInputPerMillion
        CachedInputPerMillion
        CacheCreationInputPerMillion
        ReasoningOutputPerMillion

        # Snake-cased name matching the ruby_llm symbol/key (e.g. :input_per_million).
        def key : String
          to_s.underscore
        end

        # Parse a ruby_llm-style key ("input_per_million") into an Attribute, or nil.
        def self.from_key?(key : String | Symbol) : Attribute?
          parse?(key.to_s.camelcase)
        end
      end

      def initialize(data : Hash(Attribute, Float64?) = {} of Attribute => Float64?)
        @values = {} of Attribute => Float64

        data.each do |key, value|
          self[key] = value
        end
      end

      # Convenience overload accepting ruby_llm-style string/symbol keys.
      def self.new(data : Hash(String, Float64?))
        new(string_keyed(data))
      end

      def self.new(data : Hash(Symbol, Float64?))
        new(string_keyed(data))
      end

      private def self.string_keyed(data : Hash(String, Float64?) | Hash(Symbol, Float64?)) : Hash(Attribute, Float64?)
        out = {} of Attribute => Float64?
        data.each do |key, value|
          if attr = Attribute.from_key?(key)
            out[attr] = value
          end
        end
        out
      end

      def input_per_million : Float64?
        @values[Attribute::InputPerMillion]?
      end

      def input_per_million=(value : Float64?)
        store(Attribute::InputPerMillion, value)
      end

      def output_per_million : Float64?
        @values[Attribute::OutputPerMillion]?
      end

      def output_per_million=(value : Float64?)
        store(Attribute::OutputPerMillion, value)
      end

      def cache_read_input_per_million : Float64?
        @values[Attribute::CacheReadInputPerMillion]?
      end

      def cache_read_input_per_million=(value : Float64?)
        store(Attribute::CacheReadInputPerMillion, value)
      end

      def cache_write_input_per_million : Float64?
        @values[Attribute::CacheWriteInputPerMillion]?
      end

      def cache_write_input_per_million=(value : Float64?)
        store(Attribute::CacheWriteInputPerMillion, value)
      end

      def cached_input_per_million : Float64?
        @values[Attribute::CachedInputPerMillion]?
      end

      def cached_input_per_million=(value : Float64?)
        store(Attribute::CachedInputPerMillion, value)
      end

      def cache_creation_input_per_million : Float64?
        @values[Attribute::CacheCreationInputPerMillion]?
      end

      def cache_creation_input_per_million=(value : Float64?)
        store(Attribute::CacheCreationInputPerMillion, value)
      end

      def reasoning_output_per_million : Float64?
        @values[Attribute::ReasoningOutputPerMillion]?
      end

      def reasoning_output_per_million=(value : Float64?)
        store(Attribute::ReasoningOutputPerMillion, value)
      end

      # Indexed read. Mirrors ruby_llm's `@values[key.to_sym]`; unknown keys return nil.
      def [](key : Attribute) : Float64?
        @values[key]?
      end

      def [](key : String | Symbol) : Float64?
        if attr = Attribute.from_key?(key)
          @values[attr]?
        end
      end

      # Indexed write, applying the same non-zero/truthy filter as the writers.
      def []=(key : Attribute, value : Float64?)
        store(key, value)
      end

      def []=(key : String | Symbol, value : Float64?)
        if attr = Attribute.from_key?(key)
          store(attr, value)
        end
      end

      def to_h : Hash(Attribute, Float64)
        @values
      end

      # ruby_llm: `@values[attribute] = value if value && value != 0.0`
      private def store(key : Attribute, value : Float64?)
        @values[key] = value if value && value != 0.0
      end
    end
  end
end
