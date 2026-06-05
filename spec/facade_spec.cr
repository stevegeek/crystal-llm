require "./spec_helper"
require "../src/crystal_llm/facade"
# The facade resolves "gpt-4o" to the real OpenAI provider, which only
# self-registers (and adds its `openai_api_key` config option) when its file is
# required. spec_helper's `crystal_llm` require does not pull in providers, so
# require it here. No network: chat construction never hits the wire.
require "../src/crystal_llm/providers/openai"

# Test-support reopen: `@@logger`/`@@config` are private memoized class vars on
# the CrystalLLM module (defined in src/crystal_llm.cr). Reopening the module here
# (rather than editing that file) lets the logger spec reset them to nil so the
# memoization branch (`config.logger || ::Log.for("CrystalLLM")`) can be exercised
# deterministically regardless of what earlier specs already memoized.
module CrystalLLM
  def self.reset_logger_state_for_spec! : Nil
    @@logger = nil
    @@config = nil
  end
end

describe "CrystalLLM facade" do
  describe ".chat" do
    it "returns a CrystalLLM::Chat for a known model (no network)" do
      # Chat construction only resolves the model from the registry + builds the
      # provider; the openai provider requires an api key to construct.
      CrystalLLM.config.openai_api_key = "test"

      chat = CrystalLLM.chat(model: "gpt-4o")
      chat.should be_a(CrystalLLM::Chat)
      chat.model.id.should eq("gpt-4o")
    ensure
      CrystalLLM.config.openai_api_key = nil
    end

    it "forwards provider explicitly" do
      CrystalLLM.config.openai_api_key = "test"

      chat = CrystalLLM.chat(model: "gpt-4o", provider: "openai")
      chat.should be_a(CrystalLLM::Chat)
    ensure
      CrystalLLM.config.openai_api_key = nil
    end

    it "raises when assume_model_exists is true but no provider is given" do
      expect_raises(ArgumentError, /Provider must be specified/) do
        CrystalLLM.chat(model: "made-up", assume_model_exists: true)
      end
    end
  end

  describe ".models" do
    it "returns the model registry singleton" do
      CrystalLLM.models.should be_a(CrystalLLM::Models)
      CrystalLLM.models.should be(CrystalLLM::Models.instance)
    end

    it "is a non-empty registry of Model::Info" do
      CrystalLLM.models.empty?.should be_false
      CrystalLLM.models.all.first.should be_a(CrystalLLM::Model::Info)
    end
  end

  describe ".providers" do
    it "returns the registered provider classes" do
      providers = CrystalLLM.providers
      providers.should be_a(Array(CrystalLLM::Provider.class))
      providers.should contain(CrystalLLM::Providers::OpenAI)
    end
  end

  describe ".context" do
    it "builds a Context over an independent copy of the global config" do
      original = CrystalLLM.config.default_model

      ctx = CrystalLLM.context do |cfg|
        cfg.default_model = "context-only-model"
      end

      ctx.should be_a(CrystalLLM::Context)
      ctx.config.default_model.should eq("context-only-model")
      # global config is untouched (the copy is independent)
      CrystalLLM.config.default_model.should eq(original)
    end

    it "supports a no-block variant" do
      ctx = CrystalLLM.context
      ctx.should be_a(CrystalLLM::Context)
      ctx.config.default_model.should eq(CrystalLLM.config.default_model)
    end
  end

  # #19: `CrystalLLM.logger` returns `config.logger` when one is set, otherwise
  # memoizes a default `::Log.for("CrystalLLM")`. Both branches require resetting
  # the memoized `@@logger`/`@@config` (offline; no backend wiring).
  describe ".logger" do
    after_each do
      CrystalLLM.reset_logger_state_for_spec!
      CrystalLLM.config.logger = nil
    end

    it "returns the configured logger when config.logger is set" do
      CrystalLLM.reset_logger_state_for_spec!
      custom = ::Log.for("CustomCrystalLLMSpecLogger")
      CrystalLLM.config.logger = custom

      CrystalLLM.logger.should be(custom)
    end

    it "memoizes a default ::Log.for(\"CrystalLLM\") when none is configured" do
      CrystalLLM.reset_logger_state_for_spec!
      CrystalLLM.config.logger = nil

      first = CrystalLLM.logger
      first.should be_a(::Log)
      first.source.should eq("CrystalLLM")
      # Memoized: the same instance is returned on subsequent calls.
      CrystalLLM.logger.should be(first)
    end
  end

  # Parity quick win: `CrystalLLM.deprecator` exposes the shared, memoized
  # Deprecator (ruby_llm's `@deprecator ||= Deprecator.new`).
  describe ".deprecator" do
    it "returns a memoized Deprecator instance" do
      CrystalLLM.deprecator.should be_a(CrystalLLM::Deprecator)
      CrystalLLM.deprecator.should be(CrystalLLM.deprecator)
    end
  end
end
