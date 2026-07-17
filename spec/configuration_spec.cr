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

    it "defaults tool_concurrency to false" do
      CrystalLLM::Configuration.new.tool_concurrency.should eq(false)
    end

    it "accepts a String tool_concurrency mode" do
      config = CrystalLLM::Configuration.new
      config.tool_concurrency = "fibers"
      config.tool_concurrency.should eq("fibers")
    end
  end

  # ruby_llm 93a47e3b: the `option` DSL strips blank strings to nil in every setter.
  # The Crystal port has no shared setter hook (plain typed `property`), so this is
  # ported per-option via the `nilable_string_option` macro (see configuration.cr).
  describe "blank-value normalization (ruby_llm 93a47e3b)" do
    it "normalizes blank strings to nil on nilable string options" do
      config = CrystalLLM::Configuration.new
      config.openai_api_key = "   "
      config.openai_api_key.should be_nil
      config.openai_api_key = "sk-real"
      config.openai_api_key.should eq("sk-real")
    end

    it "normalizes an empty string to nil" do
      config = CrystalLLM::Configuration.new
      config.http_proxy = ""
      config.http_proxy.should be_nil
    end

    it "leaves nil as nil" do
      config = CrystalLLM::Configuration.new
      config.http_proxy = nil
      config.http_proxy.should be_nil
    end

    it "leaves a non-blank value untouched" do
      config = CrystalLLM::Configuration.new
      config.http_proxy = "  http://proxy.internal:8080  "
      config.http_proxy.should eq("  http://proxy.internal:8080  ")
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

describe "CrystalLLM::Configuration#inspect (secret redaction)" do
  it "does not leak a set api key in inspect output" do
    config = CrystalLLM::Configuration.new
    config.openai_api_key = "sk-secret-key-should-not-appear"
    output = config.inspect
    output.should_not contain("sk-secret-key-should-not-appear")
    output.should contain("[REDACTED]")
  end

  it "shows nil for an unset secret option" do
    config = CrystalLLM::Configuration.new
    # openai_api_key defaults to nil
    config.inspect.should contain("openai_api_key=nil")
  end

  it "shows non-secret options in clear text" do
    config = CrystalLLM::Configuration.new
    config.default_model = "gpt-test"
    output = config.inspect
    output.should contain("gpt-test")
    output.should contain("default_model=")
  end

  it "redacts bedrock_secret_key and bedrock_session_token" do
    config = CrystalLLM::Configuration.new
    config.bedrock_secret_key = "my-aws-secret"
    config.bedrock_session_token = "session-token-value"
    output = config.inspect
    output.should_not contain("my-aws-secret")
    output.should_not contain("session-token-value")
  end

  it "also redacts properties added by reopening the class that contain key/secret/token" do
    config = CrystalLLM::Configuration.new
    config.fake_provider_api_key = "fake-key-12345"
    output = config.inspect
    output.should_not contain("fake-key-12345")
    output.should contain("[REDACTED]")
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
