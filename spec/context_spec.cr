require "./spec_helper"
require "../src/crystal_llm/context"

# Ported from spec/ruby_llm/context_spec.rb @ ruby_llm 1.15.0.
#
# The upstream spec drives `RubyLLM.context { |config| … }` and then asserts on
# `context.chat`, `context.embed`, model ids, and api-key error behaviour. Those
# assertions depend on Chat / Embedding / Provider, which are NOT yet ported, so
# the chat/embed examples are DEFERRED (tracked in deferrals). The portable core
# — that a Context wraps an *independent copy* of the configuration and that
# overrides never leak back to the global config or across contexts — is ported
# in full below, exercised through `Context.create`.
#
# Upstream also touches `config.openai_api_key` and `config.log_regexp_timeout`,
# neither of which exists on the ported Configuration yet (api keys arrive with
# the provider port; `log_regexp_timeout` is a Ruby-Regexp-timeout knob with no
# Crystal analog). We exercise the same copy/override semantics with properties
# that DO exist (`default_model`, `default_embedding_model`).
module ContextSpec
  describe CrystalLLM::Context do
    describe ".create" do
      it "creates an independent copy of the supplied configuration" do
        config = CrystalLLM::Configuration.new
        original_model = config.default_model
        original_embedding = config.default_embedding_model

        context = CrystalLLM::Context.create(config) do |cfg|
          cfg.default_model = "modified-model"
          cfg.default_embedding_model = "modified-embedding"
        end

        # Source config is unchanged (dup is independent).
        config.default_model.should eq(original_model)
        config.default_embedding_model.should eq(original_embedding)

        # Context carries the overrides.
        context.config.default_model.should eq("modified-model")
        context.config.default_embedding_model.should eq("modified-embedding")
      end

      it "exposes the wrapped config via #config" do
        config = CrystalLLM::Configuration.new
        context = CrystalLLM::Context.new(config)
        context.config.should be(config)
      end

      it "supports a no-block copy" do
        config = CrystalLLM::Configuration.new
        config.default_model = "base-model"

        context = CrystalLLM::Context.create(config)

        context.config.default_model.should eq("base-model")
        # Still an independent copy, not the same object.
        context.config.should_not be(config)
      end
    end

    describe "multiple independent contexts" do
      it "allows multiple contexts with different configurations" do
        config = CrystalLLM::Configuration.new

        context1 = CrystalLLM::Context.create(config) do |cfg|
          cfg.default_model = "model-1"
        end
        context2 = CrystalLLM::Context.create(config) do |cfg|
          cfg.default_model = "model-2"
        end

        context1.config.default_model.should eq("model-1")
        context2.config.default_model.should eq("model-2")
      end

      it "ensures changes in one context do not affect another" do
        config = CrystalLLM::Configuration.new

        context1 = CrystalLLM::Context.create(config) do |cfg|
          cfg.default_model = "model-1"
          cfg.default_embedding_model = "embed-1"
        end
        context2 = CrystalLLM::Context.create(config) do |cfg|
          cfg.default_model = "model-2"
          cfg.default_embedding_model = "embed-2"
        end

        # Mutate context1 after creation.
        context1.config.default_model = "modified-model-1"

        # context2 is untouched.
        context2.config.default_model.should eq("model-2")
        context2.config.default_embedding_model.should eq("embed-2")
      end

      it "does not leak context overrides back to the source config" do
        config = CrystalLLM::Configuration.new
        original_model = config.default_model

        context = CrystalLLM::Context.create(config) do |cfg|
          cfg.default_model = "scoped"
        end
        # Further mutate the context's copy.
        context.config.default_model = "scoped-again"

        config.default_model.should eq(original_model)
      end
    end
  end
end
