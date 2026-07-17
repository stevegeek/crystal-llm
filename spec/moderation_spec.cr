require "./spec_helper"
require "./support/stub_connection"
require "../src/crystal_llm/moderation"
require "../src/crystal_llm/providers/openai"
require "../src/crystal_llm/provider_media"

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

# ---------------------------------------------------------------------------
# Offline moderation pipeline tests: render → POST → parse via StubConnection
# (the offline analog of ruby_llm's VCR moderation specs)
# ---------------------------------------------------------------------------

private def configured_openai_moderate : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "sk-test"
  CrystalLLM::Providers::OpenAI.new(config)
end

private SAFE_MODERATION_BODY = {
  "id"      => "modr-001",
  "model"   => "omni-moderation-latest",
  "results" => [
    {
      "flagged"         => false,
      "categories"      => {"harassment" => false, "hate" => false, "violence" => false},
      "category_scores" => {"harassment" => 0.001, "hate" => 0.002, "violence" => 0.003},
    },
  ],
}.to_json

private FLAGGED_MODERATION_BODY = {
  "id"      => "modr-002",
  "model"   => "omni-moderation-latest",
  "results" => [
    {
      "flagged"         => true,
      "categories"      => {"harassment" => false, "hate" => true, "violence" => false},
      "category_scores" => {"harassment" => 0.01, "hate" => 0.95, "violence" => 0.02},
    },
  ],
}.to_json

describe "CrystalLLM::Provider#moderate pipeline (offline)" do
  describe "single text input" do
    it "POSTs to the moderation URL with model + input and returns a Moderation" do
      provider = configured_openai_moderate
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(SAFE_MODERATION_BODY)
      provider.connection = stub

      result = provider.moderate("totally fine text", model: "omni-moderation-latest")

      stub.posts.size.should eq(1)
      url, payload_str = stub.posts.first
      url.should eq("moderations")

      payload = JSON.parse(payload_str)
      payload["model"].as_s.should eq("omni-moderation-latest")
      payload["input"].as_s.should eq("totally fine text")

      result.should be_a(CrystalLLM::Moderation)
      result.id.should eq("modr-001")
      result.model.should eq("omni-moderation-latest")
      result.flagged?.should be_false
    end

    it "detects flagged content in the response" do
      provider = configured_openai_moderate
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(FLAGGED_MODERATION_BODY)
      provider.connection = stub

      result = provider.moderate("harmful content", model: "omni-moderation-latest")

      result.flagged?.should be_true
      result.flagged_categories.should contain("hate")
    end
  end

  describe "batch input (Array(String))" do
    it "sends the input as a JSON array when given an array" do
      provider = configured_openai_moderate
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(SAFE_MODERATION_BODY)
      provider.connection = stub

      provider.moderate(["text one", "text two"], model: "omni-moderation-latest")

      payload = JSON.parse(stub.posts.first[1])
      payload["input"].as_a.map(&.as_s).should eq(["text one", "text two"])
    end
  end

  describe "error handling" do
    it "raises Error when the response body contains an error field" do
      provider = configured_openai_moderate
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      error_body = %({"error": {"message": "invalid_model", "type": "invalid_request_error"}})
      stub.stub_response(error_body, status: 400)
      provider.connection = stub

      expect_raises(CrystalLLM::Error, "invalid_model") do
        provider.moderate("text", model: "omni-moderation-latest")
      end
    end
  end
end
