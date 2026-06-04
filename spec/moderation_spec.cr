require "./spec_helper"
require "../src/crystal_llm/moderation"

# Unit spec for the Moderation DATA object (ruby_llm's integration/VCR
# moderation_spec.rb is NOT ported — `.moderate` needs a Provider; deferred).
# Exercises the data accessors against hand-built JSON::Any results.
describe CrystalLLM::Moderation do
  # A "safe" result: nothing flagged.
  safe = JSON.parse(%({
    "flagged": false,
    "categories": {"hate": false, "violence": false},
    "category_scores": {"hate": 0.001, "violence": 0.002}
  }))

  # A "flagged" result: two categories tripped.
  flagged = JSON.parse(%({
    "flagged": true,
    "categories": {"hate": true, "violence": false, "harassment": true},
    "category_scores": {"hate": 0.9, "violence": 0.1, "harassment": 0.8}
  }))

  describe "data accessors" do
    it "exposes id, model and results" do
      mod = CrystalLLM::Moderation.new(id: "modr-123", model: "omni-moderation-latest", results: [safe])
      mod.id.should eq("modr-123")
      mod.model.should eq("omni-moderation-latest")
      mod.results.should eq([safe])
    end

    it "content returns results" do
      mod = CrystalLLM::Moderation.new(id: "x", model: "m", results: [safe])
      mod.content.should eq(mod.results)
    end
  end

  describe "#flagged?" do
    it "is false when no result is flagged" do
      CrystalLLM::Moderation.new(id: "x", model: "m", results: [safe]).flagged?.should be_false
    end

    it "is true when any result is flagged" do
      CrystalLLM::Moderation.new(id: "x", model: "m", results: [safe, flagged]).flagged?.should be_true
    end

    it "is false for an empty result set" do
      CrystalLLM::Moderation.new(id: "x", model: "m", results: [] of JSON::Any).flagged?.should be_false
    end
  end

  describe "#flagged_categories" do
    it "collects only the truthy categories across results, uniq'd" do
      mod = CrystalLLM::Moderation.new(id: "x", model: "m", results: [flagged, flagged])
      mod.flagged_categories.sort.should eq(["harassment", "hate"])
    end

    it "is empty when nothing is flagged" do
      mod = CrystalLLM::Moderation.new(id: "x", model: "m", results: [safe])
      mod.flagged_categories.should eq([] of String)
    end
  end

  describe "#categories / #category_scores" do
    it "returns the first result's categories" do
      mod = CrystalLLM::Moderation.new(id: "x", model: "m", results: [flagged, safe])
      mod.categories["hate"].as_bool.should be_true
    end

    it "returns the first result's category_scores" do
      mod = CrystalLLM::Moderation.new(id: "x", model: "m", results: [flagged, safe])
      mod.category_scores["hate"].as_f.should eq(0.9)
    end

    it "returns an empty hash when there are no results" do
      mod = CrystalLLM::Moderation.new(id: "x", model: "m", results: [] of JSON::Any)
      mod.categories.should eq({} of String => JSON::Any)
      mod.category_scores.should eq({} of String => JSON::Any)
    end
  end
end
