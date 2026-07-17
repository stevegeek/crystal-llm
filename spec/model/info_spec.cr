require "../spec_helper"
require "../../src/crystal_llm/model/info"

# Build a Model::Info from a ruby_llm-style registry hash (the wire shape:
# String keys, JSON values).
private def info_data : Hash(String, JSON::Any)
  JSON.parse({
    "id"                => "gpt-5",
    "name"              => "GPT-5",
    "provider"          => "openai",
    "family"            => "gpt",
    "created_at"        => "2026-02-20 00:00:00 UTC",
    "context_window"    => 400_000,
    "max_output_tokens" => 128_000,
    "knowledge_cutoff"  => "2025-10-01",
    "modalities"        => {"input" => ["text", "image"], "output" => ["text"]},
    "capabilities"      => ["function_calling", "streaming", "vision", "structured_output"],
    "pricing"           => {"text_tokens" => {"standard" => {"input" => 2.50, "output" => 10.00}}},
    "metadata"          => {
      "description"       => "A test model",
      "reasoning_options" => [
        {"type" => "effort", "values" => ["low", "medium", "high"]},
        {"type" => "budget_tokens", "min" => 1024},
      ],
    },
  }.to_json).as_h
end

private def info_with(overrides : Hash(String, JSON::Any)) : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.new(info_data.merge(overrides))
end

private def jany(value) : JSON::Any
  JSON.parse(value.to_json)
end

describe CrystalLLM::Model::Info do
  describe "#initialize" do
    it "assigns basic attributes" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.id.should eq("gpt-5")
      info.name.should eq("GPT-5")
      info.provider.should eq("openai")
      info.family.should eq("gpt")
      info.context_window.should eq(400_000)
      info.max_output_tokens.should eq(128_000)
    end

    it "parses created_at and knowledge_cutoff" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.created_at.should be_a(Time)
      info.knowledge_cutoff.should be_a(Time)
    end

    it "normalizes time to UTC" do
      info = info_with({"created_at" => jany("2026-02-20 00:00:00 +0700")})
      info.created_at.should_not be_nil
      created = info.created_at.as(Time)
      created.location.should eq(Time::Location::UTC)
      created.should eq(Time.utc(2026, 2, 19, 17, 0, 0))
    end

    it "builds modalities" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.modalities.should be_a(CrystalLLM::Model::Modalities)
      info.modalities.input.should eq(["text", "image"])
      info.modalities.output.should eq(["text"])
    end

    it "builds pricing" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.pricing.should be_a(CrystalLLM::Model::Pricing)
    end

    it "defaults missing optional fields" do
      minimal = CrystalLLM::Model::Info.new(
        JSON.parse({"id" => "test", "name" => "Test", "provider" => "openai"}.to_json).as_h
      )
      minimal.capabilities.should eq([] of String)
      minimal.metadata.should eq({} of String => JSON::Any)
      minimal.reasoning_options.should eq([] of Hash(String, JSON::Any))
      minimal.modalities.input.should eq([] of String)
    end
  end

  describe ".default" do
    it "creates an info with assumed capabilities" do
      default_info = CrystalLLM::Model::Info.default("my-custom-model", "openai")
      default_info.id.should eq("my-custom-model")
      default_info.provider.should eq("openai")
      default_info.capabilities.should contain("function_calling")
      default_info.capabilities.should contain("streaming")
      default_info.metadata.has_key?("warning").should be_true
    end
  end

  describe "#supports?" do
    it "returns true for included capabilities" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.supports?(:function_calling).should be_true
      info.supports?("streaming").should be_true
    end

    it "returns false for missing capabilities" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.supports?(:batch).should be_false
    end
  end

  describe "capability predicates" do
    it "responds to dynamic capability methods" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.function_calling?.should be_true
      info.structured_output?.should be_true
      info.streaming?.should be_true
      info.batch?.should be_false
      info.reasoning?.should be_false
    end
  end

  describe "#supports_vision?" do
    it "returns true when image is in input modalities" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.supports_vision?.should be_true
    end

    it "returns false when image is not in input modalities" do
      text_only = info_with({"modalities" => jany({"input" => ["text"], "output" => ["text"]})})
      text_only.supports_vision?.should be_false
    end
  end

  # ported from ruby_llm's info_spec.rb "#reasoning_options" (@ 1.16.0, commit
  # 3f27b864). ruby_llm compares symbol-keyed Hashes; the port has no runtime
  # symbols, so expectations use String-keyed Hash(String, JSON::Any) built via
  # `jany`.
  describe "#reasoning_options" do
    it "normalizes metadata reasoning options" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.reasoning_options.should eq([
        {"type" => jany("effort"), "values" => jany(["low", "medium", "high"])},
        {"type" => jany("budget_tokens"), "min" => jany(1024)},
      ])
    end

    it "accepts top-level reasoning options and stores them in metadata" do
      top_level_info = info_with({
        "reasoning_options" => jany([{"type" => "effort", "values" => ["low", "high"]}]),
        "metadata"          => jany({} of String => JSON::Any),
      })

      top_level_info.reasoning_options.should eq([
        {"type" => jany("effort"), "values" => jany(["low", "high"])},
      ])
      top_level_info.metadata["reasoning_options"]?.should eq(jany([
        {"type" => "effort", "values" => ["low", "high"]},
      ]))
    end

    it "accepts metadata reasoning options when no top-level field is present" do
      legacy_info = info_with({
        "metadata" => jany({
          "reasoning_options" => [{"type" => "effort", "values" => ["low", "high"]}],
        }),
      })

      legacy_info.reasoning_options.should eq([
        {"type" => jany("effort"), "values" => jany(["low", "high"])},
      ])
    end

    it "prefers top-level reasoning options over metadata when both are present" do
      info = info_with({
        "reasoning_options" => jany([{"type" => "effort", "values" => ["low", "high"]}]),
        "metadata"          => jany({
          "reasoning_options" => [{"type" => "budget_tokens", "min" => 1024}],
        }),
      })

      info.reasoning_options.should eq([
        {"type" => jany("effort"), "values" => jany(["low", "high"])},
      ])
    end

    it "normalizes option values to strings (e.g. JSON numbers)" do
      numeric_info = info_with({
        "metadata" => jany({
          "reasoning_options" => [{"type" => "effort", "values" => [1, 2, 3]}],
        }),
      })

      numeric_info.reasoning_options.should eq([
        {"type" => jany("effort"), "values" => jany(["1", "2", "3"])},
      ])
    end

    it "drops non-Hash entries" do
      mixed_info = info_with({
        "metadata" => jany({
          "reasoning_options" => [{"type" => "effort", "values" => ["low"]}, "garbage", 42],
        }),
      })

      mixed_info.reasoning_options.should eq([
        {"type" => jany("effort"), "values" => jany(["low"])},
      ])
    end

    it "returns option values by type" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.reasoning_option_values("effort").should eq(["low", "medium", "high"])
      # budget_tokens has no "values" key -> []
      info.reasoning_option_values("budget_tokens").should eq([] of String)
      info.reasoning_option_values("nonexistent").should eq([] of String)
    end

    it "#reasoning_option finds by type and returns nil when absent" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.reasoning_option("effort").should eq({"type" => jany("effort"), "values" => jany(["low", "medium", "high"])})
      info.reasoning_option("nonexistent").should be_nil
    end
  end

  describe "#type" do
    it "returns chat for text output models" do
      CrystalLLM::Model::Info.new(info_data).type.should eq("chat")
    end

    it "returns embedding for output models that include embeddings" do
      info_with({"modalities" => jany({"input" => ["text"], "output" => ["embeddings"]})}).type.should eq("embedding")
    end

    it "returns image for output models that include image" do
      info_with({"modalities" => jany({"input" => ["text"], "output" => ["image"]})}).type.should eq("image")
    end

    it "returns image for mixed text+image output models" do
      info_with({"modalities" => jany({"input" => ["text"], "output" => ["text", "image"]})}).type.should eq("image")
    end

    it "returns audio for mixed text+audio output models" do
      info_with({"modalities" => jany({"input" => ["text"], "output" => ["text", "audio"]})}).type.should eq("audio")
    end

    it "returns embedding for mixed text+embeddings output models" do
      info_with({"modalities" => jany({"input" => ["text"], "output" => ["text", "embeddings"]})}).type.should eq("embedding")
    end

    it "returns moderation for mixed text+moderation output models" do
      info_with({"modalities" => jany({"input" => ["text"], "output" => ["text", "moderation"]})}).type.should eq("moderation")
    end

    it "returns video for video output models" do
      info_with({"modalities" => jany({"input" => ["text"], "output" => ["video"]})}).type.should eq("video")
    end
  end

  describe "#display_name" do
    it "returns the name" do
      CrystalLLM::Model::Info.new(info_data).display_name.should eq("GPT-5")
    end
  end

  describe "#label" do
    # DEFERRED: ruby_llm resolves provider_class.name -> "OpenAI" via the Provider
    # registry (not ported). label currently falls back to the provider slug.
    it "returns provider and display name (provider slug fallback until Provider lands)" do
      CrystalLLM::Model::Info.new(info_data).label.should eq("openai - GPT-5")
    end
  end

  describe "#max_tokens" do
    it "returns max_output_tokens" do
      CrystalLLM::Model::Info.new(info_data).max_tokens.should eq(128_000)
    end
  end

  describe "#input_price_per_million and #output_price_per_million" do
    it "delegates to pricing" do
      info = CrystalLLM::Model::Info.new(info_data)
      info.input_price_per_million.should eq(info.pricing.text_tokens.input)
      info.output_price_per_million.should eq(info.pricing.text_tokens.output)
    end
  end

  describe "cache price helpers" do
    it "delegates to cache read and write pricing" do
      info = info_with({
        "pricing" => jany({
          "text_tokens" => {
            "standard" => {
              "cache_read_input_per_million"  => 0.5,
              "cache_write_input_per_million" => 2.5,
            },
          },
        }),
      })

      info.cache_read_input_price_per_million.should eq(0.5)
      info.cache_write_input_price_per_million.should eq(2.5)
      info.cached_input_price_per_million.should eq(0.5)
      info.cache_creation_input_price_per_million.should eq(2.5)
    end
  end

  describe "#cost_for" do
    it "builds a Cost for the supplied tokens" do
      info = info_with({
        "pricing" => jany({
          "text_tokens" => {
            "standard" => {
              "input_per_million"  => 2.50,
              "output_per_million" => 10.00,
            },
          },
        }),
      })
      tokens = CrystalLLM::Tokens.new(input: 1_000, output: 2_000)

      info.cost_for(tokens).total.should eq(0.0225)
    end
  end

  describe "#to_h" do
    it "returns a hash representation" do
      hash = CrystalLLM::Model::Info.new(info_data).to_h

      hash[:id].should eq(jany("gpt-5"))
      hash[:provider].should eq(jany("openai"))
      hash[:modalities].as(JSON::Any).as_h?.should_not be_nil
      hash[:pricing].as(JSON::Any).as_h?.should_not be_nil
      hash[:capabilities].as(JSON::Any).as_a.map(&.as_s).should contain("function_calling")
      # reasoning_options is not a top-level key (ruby_llm parity) — it lives
      # inside metadata (store_reasoning_options_metadata).
      hash.has_key?(:reasoning_options).should be_false
      metadata_hash = hash[:metadata].as(JSON::Any).as_h
      metadata_hash["reasoning_options"].should eq(jany([
        {"type" => "effort", "values" => ["low", "medium", "high"]},
        {"type" => "budget_tokens", "min" => 1024},
      ]))
    end
  end
end
