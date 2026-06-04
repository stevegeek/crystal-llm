require "../spec_helper"
require "../../src/crystal_llm/model/pricing_category"

private def json(hash : Hash) : Hash(String, JSON::Any)
  JSON.parse(hash.to_json).as_h
end

describe CrystalLLM::Model::PricingCategory do
  describe "#initialize" do
    it "builds no tiers from empty data" do
      cat = CrystalLLM::Model::PricingCategory.new
      cat.standard.should be_nil
      cat.batch.should be_nil
    end

    it "builds a standard tier from wire data" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"input_per_million" => 3.0, "output_per_million" => 15.0},
      }))
      cat.standard.should_not be_nil
      cat.batch.should be_nil
    end

    it "builds both standard and batch tiers" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"input_per_million" => 3.0},
        "batch"    => {"input_per_million" => 1.5},
      }))
      cat.standard.should_not be_nil
      cat.batch.should_not be_nil
    end

    it "treats an all-zero/nil tier as empty" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"input_per_million" => 0.0, "output_per_million" => 0.0},
        "batch"    => {} of String => Float64,
      }))
      cat.standard.should be_nil
      cat.batch.should be_nil
    end

    it "accepts already-built tiers via the keyword constructor" do
      tier = CrystalLLM::Model::PricingTier.new({"input_per_million" => 2.0.as(Float64?)})
      cat = CrystalLLM::Model::PricingCategory.new(standard: tier)
      cat.standard.should be(tier)
      cat.batch.should be_nil
    end
  end

  describe "delegating accessors" do
    it "reads input and output from the standard tier" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"input_per_million" => 3.0, "output_per_million" => 15.0},
      }))
      cat.input.should eq(3.0)
      cat.output.should eq(15.0)
    end

    it "returns nil for accessors when there is no standard tier" do
      cat = CrystalLLM::Model::PricingCategory.new
      cat.input.should be_nil
      cat.output.should be_nil
      cat.cache_read_input.should be_nil
      cat.cache_write_input.should be_nil
      cat.reasoning_output.should be_nil
    end

    it "reads cache_read_input directly" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"cache_read_input_per_million" => 0.3},
      }))
      cat.cache_read_input.should eq(0.3)
    end

    it "falls back to cached_input_per_million for cache_read_input" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"cached_input_per_million" => 0.25},
      }))
      cat.cache_read_input.should eq(0.25)
    end

    it "reads cache_write_input directly" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"cache_write_input_per_million" => 3.75},
      }))
      cat.cache_write_input.should eq(3.75)
    end

    it "falls back to cache_creation_input_per_million for cache_write_input" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"cache_creation_input_per_million" => 3.5},
      }))
      cat.cache_write_input.should eq(3.5)
    end

    it "reads reasoning_output" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"reasoning_output_per_million" => 60.0},
      }))
      cat.reasoning_output.should eq(60.0)
    end
  end

  describe "aliases" do
    it "cached_input mirrors cache_read_input" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"cache_read_input_per_million" => 0.3},
      }))
      cat.cached_input.should eq(cat.cache_read_input)
      cat.cached_input.should eq(0.3)
    end

    it "cache_creation_input mirrors cache_write_input" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"cache_write_input_per_million" => 3.75},
      }))
      cat.cache_creation_input.should eq(cat.cache_write_input)
      cat.cache_creation_input.should eq(3.75)
    end
  end

  describe "#[]" do
    it "returns standard for any non-batch key" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"input_per_million" => 3.0},
        "batch"    => {"input_per_million" => 1.5},
      }))
      cat["standard"].should be(cat.standard)
      cat["anything"].should be(cat.standard)
      cat[:standard].should be(cat.standard)
    end

    it "returns batch for the batch key" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"input_per_million" => 3.0},
        "batch"    => {"input_per_million" => 1.5},
      }))
      cat["batch"].should be(cat.batch)
      cat[:batch].should be(cat.batch)
    end
  end

  describe "#to_h" do
    it "is empty when no tiers are present" do
      CrystalLLM::Model::PricingCategory.new.to_h.should be_empty
    end

    it "includes only the present tiers" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"input_per_million" => 3.0},
        "batch"    => {"input_per_million" => 1.5},
      }))
      h = cat.to_h
      h.keys.should eq(["standard", "batch"])
      h["standard"][CrystalLLM::Model::PricingTier::Attribute::InputPerMillion].should eq(3.0)
      h["batch"][CrystalLLM::Model::PricingTier::Attribute::InputPerMillion].should eq(1.5)
    end

    it "omits the batch key when batch is absent" do
      cat = CrystalLLM::Model::PricingCategory.new(json({
        "standard" => {"input_per_million" => 3.0},
      }))
      cat.to_h.keys.should eq(["standard"])
    end
  end
end
