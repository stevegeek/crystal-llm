# ported from lib/ruby_llm/model/pricing.rb @ ruby_llm 1.16.0
require "json"
require "./pricing_category"

module CrystalLLM
  module Model
    # A collection that manages and provides access to different categories of
    # pricing information (text tokens, images, audio tokens, embeddings).
    #
    # Divergences from ruby_llm:
    # - ruby_llm's `CATEGORIES` is a list of symbols and `data[category]` reads a
    #   symbol-keyed registry hash. The port takes wire data as
    #   `Hash(String, JSON::Any)` (design §11: JSON::Any on the wire) and looks up
    #   the "text_tokens"/"images"/"audio_tokens"/"embeddings" String keys.
    # - `@data` is keyed by `Category` (an enum mirroring `CATEGORIES`) rather than
    #   Ruby symbols; `to_h` returns String-keyed category names.
    class Pricing
      # ruby_llm's `CATEGORIES = %i[text_tokens images audio_tokens embeddings]`.
      enum Category
        TextTokens
        Images
        AudioTokens
        Embeddings

        # Registry/wire key for this category (e.g. "text_tokens").
        def key : String
          to_s.underscore
        end
      end

      def initialize(data : Hash(String, JSON::Any) = {} of String => JSON::Any)
        @data = {} of Category => PricingCategory

        Category.each do |category|
          raw = data[category.key]?
          next unless raw

          obj = raw.as_h?
          next unless obj
          next if empty_pricing?(obj)

          @data[category] = PricingCategory.new(obj)
        end
      end

      def text_tokens : PricingCategory
        category(Category::TextTokens)
      end

      def images : PricingCategory
        category(Category::Images)
      end

      def audio_tokens : PricingCategory
        category(Category::AudioTokens)
      end

      def embeddings : PricingCategory
        category(Category::Embeddings)
      end

      def to_h : Hash(String, Hash(String, Hash(PricingTier::Attribute, Float64)))
        result = {} of String => Hash(String, Hash(PricingTier::Attribute, Float64))
        @data.each do |category, value|
          result[category.key] = value.to_h
        end
        result
      end

      # ruby_llm: `@data[name] || PricingCategory.new`.
      private def category(name : Category) : PricingCategory
        @data[name]? || PricingCategory.new
      end

      # ruby_llm: a category is empty unless some standard/batch tier has a
      # non-zero, present value.
      private def empty_pricing?(data : Hash(String, JSON::Any)) : Bool
        {"standard", "batch"}.each do |tier|
          tier_value = data[tier]?
          next unless tier_value

          obj = tier_value.as_h?
          next unless obj

          obj.each_value do |value|
            num = numeric(value)
            return false if num && num != 0.0
          end
        end

        true
      end

      private def numeric(value : JSON::Any) : Float64?
        case raw = value.raw
        when Float64 then raw
        when Int64   then raw.to_f
        when Int32   then raw.to_f
        else              nil
        end
      end
    end
  end
end
