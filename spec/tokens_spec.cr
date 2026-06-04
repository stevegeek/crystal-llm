require "./spec_helper"

# Ports the contract of ruby_llm lib/ruby_llm/tokens.rb (@ 1.15.0).
describe CrystalLLM::Tokens do
  describe ".build" do
    it "returns nil when every bucket is nil" do
      CrystalLLM::Tokens.build.should be_nil
    end

    it "builds an instance when any bucket is set" do
      CrystalLLM::Tokens.build(input: 10).should be_a(CrystalLLM::Tokens)
    end
  end

  it "treats reasoning as an alias for thinking" do
    CrystalLLM::Tokens.new(thinking: 5).reasoning.should eq(5)
    CrystalLLM::Tokens.new(reasoning: 7).thinking.should eq(7)
  end

  it "exposes cache_read/cache_write aliases" do
    tokens = CrystalLLM::Tokens.new(cached: 42, cache_creation: 7)
    tokens.cache_read.should eq(42)
    tokens.cache_write.should eq(7)
  end

  it "compacts nil buckets out of to_h" do
    CrystalLLM::Tokens.new(input: 10, output: 20).to_h.should eq({
      :input_tokens => 10, :output_tokens => 20,
    })
  end
end
