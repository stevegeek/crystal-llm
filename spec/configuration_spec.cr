require "./spec_helper"

# Ports ruby_llm spec/ruby_llm/configuration_spec.rb (@ 1.15.0).
# Divergences from the Ruby gem (idiomatic Crystal):
#   - `options` returns Array(String), not Symbols (no runtime symbols in Crystal).
#   - `faraday_adapter` / `log_regexp_timeout` are Ruby/Faraday-specific and dropped.
#   - Provider api-key options (openai_api_key, …) are added when each provider is
#     ported (it reopens Configuration), so they are not asserted here yet.
describe CrystalLLM::Configuration do
  describe "DSL defaults" do
    it "applies core default values" do
      config = CrystalLLM::Configuration.new
      config.model_registry_class.should eq("Model")
      config.model_registry_source.should be_nil
      config.use_new_acts_as.should be_false
      config.request_timeout.should eq(300)
      config.max_retries.should eq(3)
      config.retry_interval.should eq(0.1)
      config.retry_backoff_factor.should eq(2)
      config.retry_interval_randomness.should eq(0.5)
      config.deprecation_behavior.should eq("warn")
    end

    it "pins the default model identifiers (guards against silent drift on re-port)" do
      config = CrystalLLM::Configuration.new
      config.default_model.should eq("gpt-5.4")
      config.default_embedding_model.should eq("text-embedding-3-small")
      config.default_moderation_model.should eq("omni-moderation-latest")
      config.default_image_model.should eq("gpt-image-1.5")
      config.default_transcription_model.should eq("whisper-1")
    end

    it "exposes a discoverable options API" do
      opts = CrystalLLM::Configuration.options
      opts.should contain("request_timeout")
      opts.should contain("default_model")
      opts.should contain("model_registry_file")
      opts.should contain("model_registry_class")
      opts.should contain("use_new_acts_as")
    end

    it "keeps use_new_acts_as as the canonical acts_as API selector" do
      config = CrystalLLM::Configuration.new
      config.use_new_acts_as = true
      config.use_new_acts_as.should be_true
    end
  end
end

# Reopening Configuration is how each provider file will add its api-key/base
# options. This proves the @type.instance_vars mechanism sees cross-file additions.
class CrystalLLM::Configuration
  property fake_provider_api_key : String? = nil
end

describe "CrystalLLM::Configuration reopening" do
  it "surfaces properties added by reopening the class in .options" do
    CrystalLLM::Configuration.options.should contain("fake_provider_api_key")
  end

  it "constructs with the reopened property at its default" do
    CrystalLLM::Configuration.new.fake_provider_api_key.should be_nil
  end
end

describe "CrystalLLM.configure" do
  it "yields the global configuration object" do
    yielded = nil.as(CrystalLLM::Configuration?)
    CrystalLLM.configure { |config| yielded = config }
    yielded.should be(CrystalLLM.config)
  end

  it "memoizes a single Configuration" do
    CrystalLLM.config.should be(CrystalLLM.config)
  end
end

describe "CrystalLLM::Configuration#[]?" do
  it "reads String options by runtime name" do
    config = CrystalLLM::Configuration.new
    config["default_model"]?.should eq("gpt-5.4")
    config["model_registry_class"]?.should eq("Model")
  end

  it "returns nil for unset or unknown keys" do
    config = CrystalLLM::Configuration.new
    config["http_proxy"]?.should be_nil
    config["nonexistent"]?.should be_nil
  end

  it "configured? reflects presence" do
    config = CrystalLLM::Configuration.new
    config.configured?("default_model").should be_true
    config.configured?("http_proxy").should be_false
  end
end
