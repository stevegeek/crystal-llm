# ported from lib/ruby_llm/cost.rb @ ruby_llm 1.16.0
require "./tokens"
require "./model/pricing_category"
require "./model/info"
require "./models"
require "./error"

module CrystalLLM
  # Represents the cost of token usage for a model response.
  #
  # Divergences from ruby_llm:
  # - `COMPONENTS` (`%i[input output cache_read cache_write thinking]`) becomes the
  #   `Component` enum; the symbol-dispatch (`public_send(component)`,
  #   `tokens_for`/`price_for` `case`) is rewritten as enum `case`es.
  # - `category` is a `Category` enum (`:text_tokens`/`:images`) rather than a
  #   runtime symbol.
  # - `input_details` (a string/symbol-keyed Hash in ruby_llm) is taken as
  #   `Hash(String, Int32?)`; only "text_tokens"/"image_tokens" are read.
  # - `model` accepts a `Model::Info` OR a `String` model id. `normalize_model`
  #   resolves a String against the registry (`Models.find`, returning nil when
  #   unknown — ruby_llm rescues `ModelNotFoundError`). ruby_llm's `to_llm`
  #   duck-typed branch is the ActiveRecord layer (a crystal-llm-marten concern):
  #   a persisted chat-model record resolves to a `Model::Info` before reaching
  #   Cost, so core needs only the String + `Model::Info` branches.
  class Cost
    # ruby_llm's `COMPONENTS`.
    enum Component
      Input
      Output
      CacheRead
      CacheWrite
      Thinking

      def key : String
        to_s.underscore
      end
    end

    # ruby_llm's `category` symbol (`:text_tokens` / `:images` / `:image`).
    enum Category
      TextTokens
      Images
    end

    PER_MILLION = 1_000_000.0

    getter tokens : Tokens?
    getter model : Model::Info?
    getter category : Category

    # ruby_llm aggregates a list of costs, preserving nil for any component that
    # is missing in any contributing cost.
    def self.aggregate(costs : Array(Cost?)) : Cost
      present = costs.compact.select(&.tokens?)
      return new(amounts: {} of Component => Float64?, has_tokens: false) if present.empty?

      missing = Component.values.select do |component|
        present.any?(&.missing?(component))
      end

      amounts = {} of Component => Float64?
      Component.each do |component|
        amounts[component] = missing.includes?(component) ? nil : aggregate_component(present, component)
      end

      new(amounts: amounts, missing: missing, has_tokens: true)
    end

    def initialize(
      @tokens : Tokens? = nil,
      model : Model::Info | String | Nil = nil,
      @amounts : Hash(Component, Float64?)? = nil,
      @missing : Array(Component) = [] of Component,
      @has_tokens : Bool? = nil,
      @category : Category = Category::TextTokens,
      @input_details : Hash(String, Int32?)? = nil,
    )
      @model = normalize_model(model)
    end

    # Mirrors ruby_llm's `normalize_model`: a String model id is resolved against
    # the registry (nil when unknown — ruby_llm rescues `ModelNotFoundError`); a
    # `Model::Info` passes through. (The `to_llm` duck-typed branch is the
    # ActiveRecord layer — out of core scope; see the class divergence note.)
    private def normalize_model(model : Model::Info | String | Nil) : Model::Info?
      case model
      in String
        begin
          Models.find(model)
        rescue ModelNotFoundError
          nil
        end
      in Model::Info
        model
      in Nil
        nil
      end
    end

    def input : Float64?
      amount_for(Component::Input)
    end

    def output : Float64?
      amount_for(Component::Output)
    end

    def cache_read : Float64?
      amount_for(Component::CacheRead)
    end

    def cache_write : Float64?
      amount_for(Component::CacheWrite)
    end

    def thinking : Float64?
      amount_for(Component::Thinking)
    end

    # ruby_llm: `alias reasoning thinking`
    def reasoning : Float64?
      thinking
    end

    # ruby_llm: `alias cached_input cache_read`
    def cached_input : Float64?
      cache_read
    end

    # ruby_llm: `alias cache_creation cache_write`
    def cache_creation : Float64?
      cache_write
    end

    def total : Float64?
      return nil unless tokens?
      return nil if Component.values.any? { |component| missing?(component) }

      costs = Component.values.compact_map { |component| amount_for(component) }
      return nil if costs.empty?

      costs.sum
    end

    def to_h : Hash(Symbol, Float64?)
      out = {} of Symbol => Float64?
      {
        :input       => input,
        :output      => output,
        :cache_read  => cache_read,
        :cache_write => cache_write,
        :thinking    => thinking,
        :total       => total,
      }.each do |key, value|
        out[key] = value unless value.nil?
      end
      out
    end

    def tokens? : Bool
      has = @has_tokens
      return has unless has.nil?

      Component.values.any? { |component| !tokens_for(component).nil? }
    end

    def missing?(component : Component) : Bool
      return @missing.includes?(component) if aggregate?
      return image_input_missing? if component.input? && detailed_image_input?
      return false if component.thinking? && !thinking_priced_separately?

      count = tokens_for(component)
      (count || 0) > 0 && price_for(component).nil?
    end

    private def self.aggregate_component(costs : Array(Cost), component : Component) : Float64?
      values = costs.compact_map(&.amount_for(component))
      values.empty? ? nil : values.sum
    end

    protected def amount_for(component : Component) : Float64?
      if amounts = @amounts
        return amounts[component]?
      end
      return image_input_amount if component.input? && detailed_image_input?

      token_count = tokens_for(component)
      return nil if token_count.nil?
      return 0.0 if token_count.zero?

      price = price_for(component)
      return nil unless price

      token_count * price / PER_MILLION
    end

    private def aggregate? : Bool
      !@amounts.nil?
    end

    protected def tokens_for(component : Component) : Int32?
      tks = tokens
      return nil unless tks

      case component
      when .input?       then tks.input
      when .output?      then tks.output
      when .cache_read?  then tks.cache_read
      when .cache_write? then tks.cache_write
      when .thinking?    then thinking_priced_separately? ? tks.thinking : nil
      else                    nil
      end
    end

    private def price_for(component : Component) : Float64?
      case component
      when .input?       then text_pricing.input
      when .output?      then output_pricing.output
      when .cache_read?  then text_pricing.cache_read_input
      when .cache_write? then text_pricing.cache_write_input
      when .thinking?    then text_pricing.reasoning_output
      else                    nil
      end
    end

    private def text_pricing : Model::PricingCategory
      model.try(&.pricing.text_tokens) || Model::PricingCategory.new
    end

    private def image_pricing : Model::PricingCategory
      model.try(&.pricing.images) || Model::PricingCategory.new
    end

    private def output_pricing : Model::PricingCategory
      (image_cost? && image_pricing.output) ? image_pricing : text_pricing
    end

    private def image_cost? : Bool
      category.images?
    end

    private def detailed_image_input? : Bool
      details = @input_details
      return false unless image_cost? && details

      image_input_parts.any? { |part| !part[:tokens].nil? }
    end

    private def image_input_amount : Float64?
      return nil if image_input_missing?

      image_input_parts.compact_map do |part|
        count = part[:tokens]
        price = part[:price]
        next if count.nil? || count.zero?
        next if price.nil?

        count * price / PER_MILLION
      end.sum
    end

    private def image_input_missing? : Bool
      image_input_parts.any? do |part|
        count = part[:tokens]
        (count || 0) > 0 && part[:price].nil?
      end
    end

    private def image_input_parts : Array(NamedTuple(tokens: Int32?, price: Float64?))
      [
        {tokens: input_detail("text_tokens"), price: text_pricing.input},
        {tokens: input_detail("image_tokens"), price: image_pricing.input || text_pricing.input},
      ]
    end

    private def input_detail(key : String) : Int32?
      @input_details.try(&.[key]?)
    end

    private def thinking_priced_separately? : Bool
      reasoning_price = text_pricing.reasoning_output
      return false unless reasoning_price

      output_price = text_pricing.output
      output_price.nil? || reasoning_price != output_price
    end
  end
end
