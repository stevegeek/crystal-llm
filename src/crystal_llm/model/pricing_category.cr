# ported from lib/ruby_llm/model/pricing_category.rb @ ruby_llm 1.16.0
require "json"
require "./pricing_tier"

module CrystalLLM
  module Model
    # Represents pricing tiers for different usage categories (standard and batch).
    #
    # Divergences from ruby_llm:
    # - ruby_llm's `initialize(data = {})` reads `data[:standard]` / `data[:batch]`
    #   symbol keys from a registry hash. The port takes wire data as
    #   `Hash(String, JSON::Any)` (design §11: JSON::Any on the wire) and looks up
    #   the "standard" / "batch" String keys, coercing each tier's inner object into
    #   the `Hash(String, Float64?)` that `PricingTier.new` accepts.
    # - `aliases` `cached_input` / `cache_creation_input` become plain delegating
    #   methods (Crystal has no `alias` for instance methods).
    # - `[]` takes a `String` (or `:standard`/`:batch` via the Symbol overload)
    #   rather than a Ruby symbol, mirroring the `key == :batch ? batch : standard`
    #   logic.
    class PricingCategory
      getter standard : PricingTier?
      getter batch : PricingTier?

      # Primary (wire) constructor: a category object like
      # `{"standard" => {...}, "batch" => {...}}` of JSON values.
      def initialize(data : Hash(String, JSON::Any) = {} of String => JSON::Any)
        std = tier_hash(data["standard"]?)
        bat = tier_hash(data["batch"]?)

        @standard = PricingTier.new(std) unless empty_tier?(std)
        @batch = PricingTier.new(bat) unless empty_tier?(bat)
      end

      # Convenience constructor for already-built tiers (used by callers that have
      # plain `PricingTier`s rather than wire data).
      def initialize(*, standard : PricingTier? = nil, batch : PricingTier? = nil)
        @standard = standard
        @batch = batch
      end

      def input : Float64?
        standard.try(&.input_per_million)
      end

      def output : Float64?
        standard.try(&.output_per_million)
      end

      def cache_read_input : Float64?
        s = standard
        return nil unless s
        s.cache_read_input_per_million || s.cached_input_per_million
      end

      def cache_write_input : Float64?
        s = standard
        return nil unless s
        s.cache_write_input_per_million || s.cache_creation_input_per_million
      end

      def reasoning_output : Float64?
        standard.try(&.reasoning_output_per_million)
      end

      # ruby_llm: `alias cached_input cache_read_input`
      def cached_input : Float64?
        cache_read_input
      end

      # ruby_llm: `alias cache_creation_input cache_write_input`
      def cache_creation_input : Float64?
        cache_write_input
      end

      # ruby_llm: `key == :batch ? batch : standard`
      def [](key : String) : PricingTier?
        key == "batch" ? batch : standard
      end

      def [](key : Symbol) : PricingTier?
        key == :batch ? batch : standard
      end

      # ruby_llm returns a symbol-keyed hash of the present tiers' `to_h`.
      def to_h : Hash(String, Hash(PricingTier::Attribute, Float64))
        result = {} of String => Hash(PricingTier::Attribute, Float64)
        if s = standard
          result["standard"] = s.to_h
        end
        if b = batch
          result["batch"] = b.to_h
        end
        result
      end

      # Coerce a tier's wire value (a JSON object, or nil) into the
      # `Hash(String, Float64?)` that `PricingTier.new` accepts. Non-numeric/absent
      # entries become nil so `empty_tier?` and the tier's own non-zero filter apply.
      private def tier_hash(value : JSON::Any?) : Hash(String, Float64?)
        coerced = {} of String => Float64?
        return coerced if value.nil?

        if obj = value.as_h?
          obj.each do |key, inner|
            coerced[key] = numeric(inner)
          end
        end
        coerced
      end

      private def numeric(value : JSON::Any) : Float64?
        case raw = value.raw
        when Float64 then raw
        when Int64   then raw.to_f
        when Int32   then raw.to_f
        else              nil
        end
      end

      # ruby_llm: nil tier, or every value nil / 0.0, counts as empty.
      private def empty_tier?(tier_data : Hash(String, Float64?)) : Bool
        return true if tier_data.empty?

        tier_data.values.all? { |v| v.nil? || v == 0.0 }
      end
    end
  end
end
