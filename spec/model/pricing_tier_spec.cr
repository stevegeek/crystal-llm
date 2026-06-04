require "../spec_helper"
require "../../src/crystal_llm/model/pricing_tier"

# Ports the contract of ruby_llm lib/ruby_llm/model/pricing_tier.rb (@ 1.15.0).
private alias Attribute = CrystalLLM::Model::PricingTier::Attribute

describe CrystalLLM::Model::PricingTier do
  describe "#initialize" do
    it "stores non-zero values" do
      tier = CrystalLLM::Model::PricingTier.new({Attribute::InputPerMillion => 2.5})
      tier.input_per_million.should eq(2.5)
    end

    it "drops zero values" do
      tier = CrystalLLM::Model::PricingTier.new({Attribute::InputPerMillion => 0.0})
      tier.input_per_million.should be_nil
      tier.to_h.empty?.should be_true
    end

    it "drops nil values" do
      tier = CrystalLLM::Model::PricingTier.new({Attribute::OutputPerMillion => nil})
      tier.output_per_million.should be_nil
    end

    it "defaults to an empty tier" do
      CrystalLLM::Model::PricingTier.new.to_h.empty?.should be_true
    end

    it "accepts ruby_llm-style string keys" do
      tier = CrystalLLM::Model::PricingTier.new({"input_per_million" => 1.0, "ignored_key" => 9.0})
      tier.input_per_million.should eq(1.0)
      tier.to_h.size.should eq(1)
    end

    it "accepts ruby_llm-style symbol keys" do
      tier = CrystalLLM::Model::PricingTier.new({:output_per_million => 3.0})
      tier.output_per_million.should eq(3.0)
    end
  end

  describe "accessors" do
    it "exposes all seven attributes" do
      tier = CrystalLLM::Model::PricingTier.new({
        Attribute::InputPerMillion              => 1.0,
        Attribute::OutputPerMillion             => 2.0,
        Attribute::CacheReadInputPerMillion     => 3.0,
        Attribute::CacheWriteInputPerMillion    => 4.0,
        Attribute::CachedInputPerMillion        => 5.0,
        Attribute::CacheCreationInputPerMillion => 6.0,
        Attribute::ReasoningOutputPerMillion    => 7.0,
      })

      tier.input_per_million.should eq(1.0)
      tier.output_per_million.should eq(2.0)
      tier.cache_read_input_per_million.should eq(3.0)
      tier.cache_write_input_per_million.should eq(4.0)
      tier.cached_input_per_million.should eq(5.0)
      tier.cache_creation_input_per_million.should eq(6.0)
      tier.reasoning_output_per_million.should eq(7.0)
    end

    it "filters zero on write (setter)" do
      tier = CrystalLLM::Model::PricingTier.new
      tier.input_per_million = 0.0
      tier.input_per_million.should be_nil
      tier.input_per_million = 4.2
      tier.input_per_million.should eq(4.2)
    end

    it "filters nil on write (setter)" do
      tier = CrystalLLM::Model::PricingTier.new
      tier.output_per_million = nil
      tier.output_per_million.should be_nil
    end
  end

  describe "#[]" do
    it "reads by enum key" do
      tier = CrystalLLM::Model::PricingTier.new({Attribute::InputPerMillion => 2.5})
      tier[Attribute::InputPerMillion].should eq(2.5)
    end

    it "reads by ruby_llm string key" do
      tier = CrystalLLM::Model::PricingTier.new({Attribute::InputPerMillion => 2.5})
      tier["input_per_million"].should eq(2.5)
    end

    it "reads by symbol key" do
      tier = CrystalLLM::Model::PricingTier.new({Attribute::InputPerMillion => 2.5})
      tier[:input_per_million].should eq(2.5)
    end

    it "returns nil for unset keys" do
      CrystalLLM::Model::PricingTier.new[Attribute::OutputPerMillion].should be_nil
    end

    it "returns nil for unknown string keys" do
      CrystalLLM::Model::PricingTier.new["nope"].should be_nil
    end
  end

  describe "#[]=" do
    it "writes by enum key with the zero filter" do
      tier = CrystalLLM::Model::PricingTier.new
      tier[Attribute::InputPerMillion] = 5.0
      tier.input_per_million.should eq(5.0)
      tier[Attribute::InputPerMillion] = 0.0
      tier.input_per_million.should eq(5.0)
    end

    it "writes by string key" do
      tier = CrystalLLM::Model::PricingTier.new
      tier["output_per_million"] = 9.0
      tier.output_per_million.should eq(9.0)
    end
  end

  describe "#to_h" do
    it "returns only the stored non-zero values" do
      tier = CrystalLLM::Model::PricingTier.new({
        Attribute::InputPerMillion  => 1.0,
        Attribute::OutputPerMillion => 0.0,
      })
      tier.to_h.should eq({Attribute::InputPerMillion => 1.0})
    end
  end

  describe "Attribute#key" do
    it "renders the ruby_llm snake_case key" do
      Attribute::CacheReadInputPerMillion.key.should eq("cache_read_input_per_million")
    end

    it "round-trips through from_key?" do
      Attribute.from_key?("reasoning_output_per_million").should eq(Attribute::ReasoningOutputPerMillion)
      Attribute.from_key?("bogus").should be_nil
    end
  end
end
