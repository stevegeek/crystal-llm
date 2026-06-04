require "./spec_helper"
require "../src/crystal_llm/model/info"
require "../src/crystal_llm/cost"

# Build a Model::Info from a ruby_llm-style registry hash (the wire shape:
# String keys, JSON values). Mirrors the Ruby spec's `Info.new(id:, pricing: ...)`.
private def model_info(hash : Hash) : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.new(JSON.parse(hash.to_json).as_h)
end

# Assert a (nilable) float cost is present and within ruby_llm's tolerance.
private def close(actual : Float64?, expected : Float64)
  actual.should_not be_nil
  actual.as(Float64).should be_close(expected, 0.0000000001)
end

describe CrystalLLM::Cost do
  model = model_info({
    "id"       => "priced-model",
    "name"     => "Priced Model",
    "provider" => "openai",
    "pricing"  => {
      "text_tokens" => {
        "standard" => {
          "input_per_million"             => 1.0,
          "output_per_million"            => 2.0,
          "cache_read_input_per_million"  => 0.25,
          "cache_write_input_per_million" => 1.25,
        },
      },
    },
  })

  describe "#total" do
    it "calculates input, output, cache read, and cache write costs from normalized token buckets" do
      tokens = CrystalLLM::Tokens.new(input: 1_000, output: 2_000, cached: 300, cache_creation: 100)
      cost = CrystalLLM::Cost.new(tokens: tokens, model: model)

      close(cost.input, 0.001)
      close(cost.output, 0.004)
      close(cost.cache_read, 0.000075)
      close(cost.cache_write, 0.000125)
      close(cost.total, 0.0052)
    end

    it "trusts input tokens as the standard input bucket" do
      tokens = CrystalLLM::Tokens.new(input: 700, cached: 300)
      cost = CrystalLLM::Cost.new(tokens: tokens, model: model)

      close(cost.input, 0.0007)
      close(cost.cache_read, 0.000075)
      close(cost.total, 0.000775)
    end

    it "keeps backwards-compatible cache cost aliases" do
      tokens = CrystalLLM::Tokens.new(input: 1_000, cached: 300, cache_creation: 100)
      cost = CrystalLLM::Cost.new(tokens: tokens, model: model)

      cost.cached_input.should eq(cost.cache_read)
      cost.cache_creation.should eq(cost.cache_write)
    end

    it "calculates image costs from text and image input details" do
      image_model = model_info({
        "id"       => "image-model",
        "name"     => "Image Model",
        "provider" => "openai",
        "pricing"  => {
          "text_tokens" => {"standard" => {"input_per_million" => 5.0}},
          "images"      => {"standard" => {"input_per_million" => 10.0, "output_per_million" => 40.0}},
        },
      })
      tokens = CrystalLLM::Tokens.new(input: 350, output: 50)
      cost = CrystalLLM::Cost.new(
        tokens: tokens,
        model: image_model,
        category: CrystalLLM::Cost::Category::Images,
        input_details: {"text_tokens" => 100, "image_tokens" => 250} of String => Int32?
      )

      close(cost.input, 0.003)
      close(cost.output, 0.002)
      close(cost.total, 0.005)
    end

    it "does not price thinking tokens separately when output already includes them" do
      tokens = CrystalLLM::Tokens.new(input: 50, output: 1306, thinking: 1087)
      cost = CrystalLLM::Cost.new(tokens: tokens, model: model)

      close(cost.output, 0.002612)
      cost.thinking.should be_nil
      cost.reasoning.should be_nil
      close(cost.total, 0.002662)
    end

    it "prices thinking tokens separately when the model has distinct reasoning pricing" do
      reasoning_model = model_info({
        "id"       => "reasoning-priced-model",
        "name"     => "Reasoning Priced Model",
        "provider" => "perplexity",
        "pricing"  => {
          "text_tokens" => {
            "standard" => {
              "input_per_million"            => 2.0,
              "output_per_million"           => 8.0,
              "reasoning_output_per_million" => 3.0,
            },
          },
        },
      })
      tokens = CrystalLLM::Tokens.new(input: 33, output: 11_395, thinking: 193_947)
      cost = CrystalLLM::Cost.new(tokens: tokens, model: reasoning_model)

      close(cost.input, 0.000066)
      close(cost.output, 0.09116)
      close(cost.thinking, 0.581841)
      close(cost.total, 0.673067)
    end

    it "does not double-count thinking tokens when reasoning pricing matches output pricing" do
      inclusive_model = model_info({
        "id"       => "inclusive-reasoning-model",
        "name"     => "Inclusive Reasoning Model",
        "provider" => "openrouter",
        "pricing"  => {
          "text_tokens" => {
            "standard" => {
              "output_per_million"           => 12.0,
              "reasoning_output_per_million" => 12.0,
            },
          },
        },
      })
      tokens = CrystalLLM::Tokens.new(output: 1_000, thinking: 800)
      cost = CrystalLLM::Cost.new(tokens: tokens, model: inclusive_model)

      cost.output.should eq(0.012)
      cost.thinking.should be_nil
      cost.total.should eq(0.012)
    end

    it "reads legacy cache pricing keys" do
      legacy_model = model_info({
        "id"       => "legacy-priced-model",
        "name"     => "Legacy Priced Model",
        "provider" => "openai",
        "pricing"  => {
          "text_tokens" => {
            "standard" => {
              "cached_input_per_million"         => 0.25,
              "cache_creation_input_per_million" => 1.25,
            },
          },
        },
      })
      tokens = CrystalLLM::Tokens.new(cached: 300, cache_creation: 100)
      cost = CrystalLLM::Cost.new(tokens: tokens, model: legacy_model)

      close(cost.cache_read, 0.000075)
      close(cost.cache_write, 0.000125)
    end

    it "returns nil when pricing is missing for tokens that were used" do
      incomplete_model = model_info({
        "id"       => "incomplete-model",
        "name"     => "Incomplete Model",
        "provider" => "openai",
        "pricing"  => {"text_tokens" => {"standard" => {"input_per_million" => 1.0}}},
      })
      tokens = CrystalLLM::Tokens.new(input: 10, output: 5)
      cost = CrystalLLM::Cost.new(tokens: tokens, model: incomplete_model)

      cost.input.should eq(0.00001)
      cost.output.should be_nil
      cost.total.should be_nil
    end

    it "does not require pricing for token buckets that were not used" do
      input_only_model = model_info({
        "id"       => "input-only-model",
        "name"     => "Input Only Model",
        "provider" => "openai",
        "pricing"  => {"text_tokens" => {"standard" => {"input_per_million" => 1.0}}},
      })
      tokens = CrystalLLM::Tokens.new(input: 10)
      cost = CrystalLLM::Cost.new(tokens: tokens, model: input_only_model)

      cost.output.should be_nil
      cost.total.should eq(0.00001)
    end

    it "returns nil when there is no token usage" do
      CrystalLLM::Cost.new(model: model).total.should be_nil
    end
  end

  describe ".aggregate" do
    it "sums costs while preserving nil for missing pricing" do
      priced = CrystalLLM::Cost.new(tokens: CrystalLLM::Tokens.new(input: 10), model: model)
      missing = CrystalLLM::Cost.new(tokens: CrystalLLM::Tokens.new(output: 10), model: nil)
      aggregate = CrystalLLM::Cost.aggregate([priced, missing] of CrystalLLM::Cost?)

      aggregate.input.should eq(0.00001)
      aggregate.output.should be_nil
      aggregate.total.should be_nil
    end

    it "ignores entries without token usage" do
      priced = CrystalLLM::Cost.new(tokens: CrystalLLM::Tokens.new(input: 10), model: model)
      empty = CrystalLLM::Cost.new(model: model)
      aggregate = CrystalLLM::Cost.aggregate([empty, priced] of CrystalLLM::Cost?)

      aggregate.total.should eq(0.00001)
    end
  end
end
