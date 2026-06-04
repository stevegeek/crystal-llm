require "./spec_helper"
require "../src/crystal_llm/thinking"

# Ports the contract of ruby_llm lib/ruby_llm/thinking.rb (@ 1.15.0).
describe CrystalLLM::Thinking do
  describe "#initialize" do
    it "exposes text and signature readers" do
      thinking = CrystalLLM::Thinking.new(text: "reasoning", signature: "sig")
      thinking.text.should eq("reasoning")
      thinking.signature.should eq("sig")
    end

    it "defaults text and signature to nil" do
      thinking = CrystalLLM::Thinking.new
      thinking.text.should be_nil
      thinking.signature.should be_nil
    end
  end

  describe ".build" do
    it "returns nil when both text and signature are nil" do
      CrystalLLM::Thinking.build.should be_nil
    end

    it "treats an empty text as nil" do
      CrystalLLM::Thinking.build(text: "").should be_nil
    end

    it "treats an empty signature as nil" do
      CrystalLLM::Thinking.build(signature: "").should be_nil
    end

    it "returns nil when both are empty strings" do
      CrystalLLM::Thinking.build(text: "", signature: "").should be_nil
    end

    it "builds an instance when text is present" do
      thinking = CrystalLLM::Thinking.build(text: "thought")
      thinking.should be_a(CrystalLLM::Thinking)
      thinking.try(&.text).should eq("thought")
      thinking.try(&.signature).should be_nil
    end

    it "builds an instance when only signature is present" do
      thinking = CrystalLLM::Thinking.build(signature: "sig")
      thinking.should be_a(CrystalLLM::Thinking)
      thinking.try(&.text).should be_nil
      thinking.try(&.signature).should eq("sig")
    end

    it "blanks an empty text but keeps a present signature" do
      thinking = CrystalLLM::Thinking.build(text: "", signature: "sig")
      thinking.try(&.text).should be_nil
      thinking.try(&.signature).should eq("sig")
    end
  end

  describe "#inspect" do
    it "redacts the signature when present" do
      thinking = CrystalLLM::Thinking.new(text: "reasoning", signature: "secret")
      output = thinking.inspect
      output.should contain("[REDACTED]")
      output.should_not contain("secret")
      output.should contain("reasoning")
    end

    it "renders a nil signature as nil (not redacted)" do
      thinking = CrystalLLM::Thinking.new(text: "reasoning")
      output = thinking.inspect
      output.should_not contain("[REDACTED]")
      output.should contain("nil")
    end
  end
end

describe CrystalLLM::Thinking::Config do
  describe "#initialize" do
    it "exposes effort and budget readers" do
      config = CrystalLLM::Thinking::Config.new(effort: "high", budget: 1024)
      config.effort.should eq("high")
      config.budget.should eq(1024)
    end

    it "defaults effort and budget to nil" do
      config = CrystalLLM::Thinking::Config.new
      config.effort.should be_nil
      config.budget.should be_nil
    end
  end

  describe "#enabled?" do
    it "is false when both effort and budget are nil" do
      CrystalLLM::Thinking::Config.new.enabled?.should be_false
    end

    it "is true when effort is set" do
      CrystalLLM::Thinking::Config.new(effort: "low").enabled?.should be_true
    end

    it "is true when budget is set" do
      CrystalLLM::Thinking::Config.new(budget: 512).enabled?.should be_true
    end
  end
end
