require "../spec_helper"
require "../../src/crystal_llm/model/modalities"

# Ports the contract of ruby_llm lib/ruby_llm/model/modalities.rb (@ 1.15.0).
describe CrystalLLM::Model::Modalities do
  describe "#initialize from JSON data" do
    it "stringifies arrays of strings" do
      data = {
        "input"  => JSON::Any.new([JSON::Any.new("text"), JSON::Any.new("image")]),
        "output" => JSON::Any.new([JSON::Any.new("text")]),
      }
      m = CrystalLLM::Model::Modalities.new(data)
      m.input.should eq(["text", "image"])
      m.output.should eq(["text"])
    end

    it "coerces missing keys to empty arrays (Array(nil) -> [])" do
      m = CrystalLLM::Model::Modalities.new({} of String => JSON::Any)
      m.input.should eq([] of String)
      m.output.should eq([] of String)
    end

    it "coerces an explicit null to an empty array" do
      data = {
        "input"  => JSON::Any.new(nil),
        "output" => JSON::Any.new(nil),
      }
      m = CrystalLLM::Model::Modalities.new(data)
      m.input.should eq([] of String)
      m.output.should eq([] of String)
    end

    it "wraps a scalar value in a single-element array (Array(scalar))" do
      data = {
        "input"  => JSON::Any.new("text"),
        "output" => JSON::Any.new("audio"),
      }
      m = CrystalLLM::Model::Modalities.new(data)
      m.input.should eq(["text"])
      m.output.should eq(["audio"])
    end

    it "stringifies non-string scalars (map(&:to_s))" do
      data = {
        "input"  => JSON::Any.new([JSON::Any.new(1_i64), JSON::Any.new(true)]),
        "output" => JSON::Any.new(42_i64),
      }
      m = CrystalLLM::Model::Modalities.new(data)
      m.input.should eq(["1", "true"])
      m.output.should eq(["42"])
    end
  end

  describe "#initialize from typed arrays" do
    it "stores the given arrays" do
      m = CrystalLLM::Model::Modalities.new(input: ["text", "image"], output: ["text"])
      m.input.should eq(["text", "image"])
      m.output.should eq(["text"])
    end

    it "defaults both to empty arrays" do
      m = CrystalLLM::Model::Modalities.new
      m.input.should eq([] of String)
      m.output.should eq([] of String)
    end
  end

  describe "#to_h" do
    it "returns a symbol-keyed hash of input and output" do
      m = CrystalLLM::Model::Modalities.new(input: ["text", "image"], output: ["text"])
      m.to_h.should eq({:input => ["text", "image"], :output => ["text"]})
    end
  end
end
