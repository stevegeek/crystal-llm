# ported from lib/ruby_llm/model/info.rb @ ruby_llm 1.16.0
require "json"
require "./modalities"
require "./pricing"
require "../tokens"
require "../cost"

module CrystalLLM
  module Model
    # Information about an AI model's capabilities, pricing, and metadata.
    #
    # Divergences from ruby_llm:
    # - ruby_llm's `initialize(data)` reads a symbol-keyed registry hash whose
    #   values are heterogeneous (String/Integer/Hash/Array). The port takes wire
    #   data as `Hash(String, JSON::Any)` (design §11: JSON::Any on the wire) and
    #   coerces each field. A `.build` keyword convenience constructor is also
    #   provided for callers that hold native values.
    # - The dynamic `%w[...].each { define_method "#{cap}?" }` capability
    #   predicates are written out explicitly (Crystal has no runtime
    #   `define_method`).
    # - `created_at`/`knowledge_cutoff` use `to_time`/`to_date` defined inline on
    #   this class (not in Utils); `to_time` normalizes to UTC.
    # - DEFERRED: `provider_class` is not wired — returns nil; `label` therefore
    #   falls back to the raw provider slug rather than the provider's display name.
    # - `reasoning_options` (ruby_llm 3f27b864): ruby_llm normalizes into an
    #   Array of Symbol-keyed Hashes (`transform_keys(&:to_sym)`). The port has no
    #   runtime symbols, so it stays `Array(Hash(String, JSON::Any))` — String
    #   keys throughout, per design §11.
    class Info
      getter id : String?
      getter name : String?
      getter provider : String?
      getter family : String?
      getter created_at : Time?
      getter context_window : Int32?
      getter max_output_tokens : Int32?
      getter knowledge_cutoff : Time?
      getter modalities : Modalities
      getter capabilities : Array(String)
      getter pricing : Pricing
      getter metadata : Hash(String, JSON::Any)
      getter reasoning_options : Array(Hash(String, JSON::Any))

      # Create a default model with assumed capabilities (ruby_llm's `.default`).
      def self.default(model_id : String, provider : String) : Info
        build(
          id: model_id,
          name: model_id.tr("-", " ").capitalize,
          provider: provider,
          capabilities: %w[function_calling streaming vision structured_output],
          modalities: Modalities.new(input: %w[text image], output: %w[text]),
          metadata: {"warning" => JSON::Any.new("Assuming model exists, capabilities may not be accurate")}
        )
      end

      # Primary (wire) constructor.
      def initialize(data : Hash(String, JSON::Any))
        @id = string_field(data["id"]?)
        @name = string_field(data["name"]?)
        @provider = string_field(data["provider"]?)
        @family = string_field(data["family"]?)
        @created_at = self.class.to_time(data["created_at"]?)
        @context_window = int_field(data["context_window"]?)
        @max_output_tokens = int_field(data["max_output_tokens"]?)
        @knowledge_cutoff = self.class.to_date(data["knowledge_cutoff"]?)
        @modalities = Modalities.new(hash_field(data["modalities"]?))
        @capabilities = string_array(data["capabilities"]?)
        @pricing = Pricing.new(hash_field(data["pricing"]?))
        # `.dup`: store_reasoning_options_metadata mutates @metadata in place
        # (delete + re-set "reasoning_options"); dup avoids corrupting a Hash
        # the caller (or a shared parsed JSON::Any) still holds a reference to
        # (ruby_llm: `data[:metadata]&.dup`).
        @metadata = hash_field(data["metadata"]?).dup
        @reasoning_options = normalize_reasoning_options(reasoning_options_from(data))
        store_reasoning_options_metadata
      end

      # Keyword convenience constructor for callers holding native values.
      def self.build(
        id : String? = nil,
        name : String? = nil,
        provider : String? = nil,
        family : String? = nil,
        created_at : Time? = nil,
        context_window : Int32? = nil,
        max_output_tokens : Int32? = nil,
        knowledge_cutoff : Time? = nil,
        modalities : Modalities = Modalities.new,
        capabilities : Array(String) = [] of String,
        pricing : Pricing = Pricing.new,
        metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
        reasoning_options : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
      ) : Info
        info = allocate
        info.initialize_fields(
          id, name, provider, family, created_at, context_window,
          max_output_tokens, knowledge_cutoff, modalities, capabilities,
          pricing, metadata, reasoning_options
        )
        info
      end

      # :nodoc:
      protected def initialize_fields(
        @id : String?, @name : String?, @provider : String?, @family : String?,
        @created_at : Time?, @context_window : Int32?, @max_output_tokens : Int32?,
        @knowledge_cutoff : Time?, @modalities : Modalities,
        @capabilities : Array(String), @pricing : Pricing,
        @metadata : Hash(String, JSON::Any),
        @reasoning_options : Array(Hash(String, JSON::Any)),
      )
      end

      def supports?(capability : String | Symbol) : Bool
        capabilities.includes?(capability.to_s)
      end

      # ruby_llm generates these via `define_method "#{cap}?"`.
      def function_calling? : Bool
        supports?("function_calling")
      end

      def structured_output? : Bool
        supports?("structured_output")
      end

      def batch? : Bool
        supports?("batch")
      end

      def reasoning? : Bool
        supports?("reasoning")
      end

      # Finds a reasoning-options entry by `type` (e.g. "effort", "budget_tokens").
      def reasoning_option(type : String) : Hash(String, JSON::Any)?
        reasoning_options.find { |option| option["type"]?.try(&.as_s?) == type }
      end

      # Returns the `values` array (as Strings) for the reasoning option of the
      # given `type`, or `[]` when the option or its `values` key is absent.
      def reasoning_option_values(type : String) : Array(String)
        option = reasoning_option(type)
        return [] of String unless option

        values = option["values"]?
        return [] of String unless values

        arr = values.as_a?
        return [] of String unless arr

        arr.compact_map(&.as_s?)
      end

      def citations? : Bool
        supports?("citations")
      end

      def streaming? : Bool
        supports?("streaming")
      end

      def display_name : String?
        name
      end

      def label : String
        provider_name = provider_class.try(&.name) || provider
        "#{provider_name} - #{display_name}"
      end

      def max_tokens : Int32?
        max_output_tokens
      end

      def supports_vision? : Bool
        modalities.input.includes?("image")
      end

      def supports_video? : Bool
        modalities.input.includes?("video")
      end

      def supports_functions? : Bool
        function_calling?
      end

      def input_price_per_million : Float64?
        pricing.text_tokens.input
      end

      def output_price_per_million : Float64?
        pricing.text_tokens.output
      end

      def cache_read_input_price_per_million : Float64?
        pricing.text_tokens.cache_read_input
      end

      def cache_write_input_price_per_million : Float64?
        pricing.text_tokens.cache_write_input
      end

      # ruby_llm: `alias cached_input_price_per_million cache_read_input_price_per_million`
      def cached_input_price_per_million : Float64?
        cache_read_input_price_per_million
      end

      # ruby_llm: `alias cache_creation_input_price_per_million cache_write_input_price_per_million`
      def cache_creation_input_price_per_million : Float64?
        cache_write_input_price_per_million
      end

      # ruby_llm accepts either a Tokens, or anything responding to `tokens`.
      # The port takes a `Tokens` directly; callers holding a `Message` pass
      # `message.tokens` (the `respond_to?(:tokens)` branch).
      def cost_for(tokens : Tokens) : Cost
        Cost.new(tokens: tokens, model: self)
      end

      # DEFERRED: not wired to Provider.resolve; returns nil (label falls back to slug).
      def provider_class : Nil
        nil
      end

      def type : String
        output = modalities.output
        return "embedding" if output.includes?("embeddings")
        return "moderation" if output.includes?("moderation")
        return "image" if output.includes?("image")
        return "audio" if output.includes?("audio")
        return "video" if output.includes?("video")

        "chat"
      end

      def to_h : Hash(Symbol, JSON::Any?)
        {
          :id                => wrap(id),
          :name              => wrap(name),
          :provider          => wrap(provider),
          :family            => wrap(family),
          :created_at        => wrap(created_at.try(&.to_s)),
          :context_window    => wrap(context_window),
          :max_output_tokens => wrap(max_output_tokens),
          :knowledge_cutoff  => wrap(knowledge_cutoff.try(&.to_s)),
          :modalities        => JSON.parse(modalities.to_h.transform_keys(&.to_s).to_json),
          :capabilities      => JSON.parse(capabilities.to_json),
          :pricing           => JSON.parse(pricing_to_json),
          :metadata          => JSON.parse(metadata.to_json),
        } of Symbol => JSON::Any?
      end

      # ruby_llm Utils.to_time: parse to a Time, normalized to UTC.
      def self.to_time(value : JSON::Any?) : Time?
        return nil if value.nil? || value.raw.nil?

        str = value.as_s? || value.raw.to_s
        return nil if str.empty?

        parse_time(str).to_utc
      end

      private def self.parse_time(str : String) : Time
        formats = [
          "%Y-%m-%d %H:%M:%S %z",
          "%Y-%m-%dT%H:%M:%S%z",
          "%Y-%m-%d %H:%M:%S",
          "%Y-%m-%dT%H:%M:%S",
          "%Y-%m-%d",
        ]
        formats.each do |fmt|
          begin
            return Time.parse(str, fmt, Time::Location::UTC)
          rescue Time::Format::Error
            next
          end
        end
        Time.parse_utc(str, "%Y-%m-%d %H:%M:%S")
      end

      # ruby_llm Utils.to_date: parse to a Date (modelled as a UTC midnight Time).
      def self.to_date(value : JSON::Any?) : Time?
        return nil if value.nil? || value.raw.nil?

        str = value.as_s? || value.raw.to_s
        return nil if str.empty?

        Time.parse(str, "%Y-%m-%d", Time::Location::UTC)
      end

      # pricing.to_h is keyed by `PricingTier::Attribute` (an enum, not a valid
      # JSON object key); restringify the inner tier keys before serializing.
      private def pricing_to_json : String
        stringified = pricing.to_h.transform_values do |category|
          category.transform_values do |tier|
            tier.transform_keys(&.key)
          end
        end
        stringified.to_json
      end

      private def wrap(value) : JSON::Any?
        return nil if value.nil?
        JSON.parse(value.to_json)
      end

      private def string_field(value : JSON::Any?) : String?
        return nil if value.nil?
        value.as_s? || (value.raw.nil? ? nil : value.raw.to_s)
      end

      private def int_field(value : JSON::Any?) : Int32?
        return nil if value.nil?
        case raw = value.raw
        when Int64   then raw.to_i32
        when Int32   then raw
        when Float64 then raw.to_i32
        else              nil
        end
      end

      private def hash_field(value : JSON::Any?) : Hash(String, JSON::Any)
        return {} of String => JSON::Any if value.nil?
        value.as_h? || {} of String => JSON::Any
      end

      private def string_array(value : JSON::Any?) : Array(String)
        return [] of String if value.nil?
        arr = value.as_a?
        return [] of String if arr.nil?
        arr.map { |element| element.as_s? || element.raw.to_s }
      end

      # ruby_llm: `data[:reasoning_options] || metadata[:reasoning_options] || metadata['reasoning_options']`.
      # The port's metadata is always String-keyed, so there is no separate
      # string/symbol variant to check — `data["reasoning_options"]` (the
      # top-level wire field) takes priority over `metadata["reasoning_options"]`.
      # A present-but-JSON-null value is treated as absent (Ruby `||` treats nil
      # as falsy; a JSON::Any wrapping nil is NOT Crystal `nil`, so this must be
      # checked explicitly).
      private def reasoning_options_from(data : Hash(String, JSON::Any)) : JSON::Any?
        top_level = data["reasoning_options"]?
        return top_level if top_level && !top_level.raw.nil?

        from_metadata = @metadata["reasoning_options"]?
        return from_metadata if from_metadata && !from_metadata.raw.nil?

        nil
      end

      # ruby_llm: `return unless reasoning_options.any?; metadata.delete('reasoning_options'); metadata[:reasoning_options] = reasoning_options`.
      private def store_reasoning_options_metadata : Nil
        return if reasoning_options.empty?

        @metadata.delete("reasoning_options")
        @metadata["reasoning_options"] = JSON::Any.new(reasoning_options.map { |option| JSON::Any.new(option) })
      end

      # ruby_llm: `Array(options).filter_map { |option| next unless option.is_a?(Hash); ...; normalized }`.
      # Keeps only Hash-shaped entries; stringifies `type` when present, and
      # coerces `values` (if present) to an Array of Strings.
      private def normalize_reasoning_options(options : JSON::Any?) : Array(Hash(String, JSON::Any))
        arr = options.try(&.as_a?)
        return [] of Hash(String, JSON::Any) unless arr

        arr.compact_map do |option|
          obj = option.as_h?
          next nil unless obj

          normalized = obj.dup
          if type_val = normalized["type"]?
            normalized["type"] = JSON::Any.new(reasoning_scalar_to_s(type_val)) unless type_val.raw.nil?
          end
          if normalized.has_key?("values")
            normalized["values"] = normalize_reasoning_values(normalized["values"])
          end
          normalized
        end
      end

      # ruby_llm: `Array(normalized[:values]).map(&:to_s)`.
      private def normalize_reasoning_values(value : JSON::Any) : JSON::Any
        if arr = value.as_a?
          JSON::Any.new(arr.map { |element| JSON::Any.new(reasoning_scalar_to_s(element)) })
        elsif value.raw.nil?
          JSON::Any.new([] of JSON::Any)
        else
          JSON::Any.new([JSON::Any.new(reasoning_scalar_to_s(value))])
        end
      end

      private def reasoning_scalar_to_s(value : JSON::Any) : String
        value.as_s? || value.raw.to_s
      end
    end
  end
end
