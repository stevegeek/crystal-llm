require "./spec_helper"
require "../src/crystal_llm/context"

# Ported from spec/ruby_llm/context_spec.rb @ ruby_llm 1.15.0.
#
# Covers both halves of Context: the config copy/override semantics (a Context
# wraps an *independent copy* of the configuration; overrides never leak back to
# the global config or across contexts) AND the per-call entrypoints
# (`chat`/`embed`/`moderate`/`transcribe`/`paint`/`connection_for`), which forward
# to the matching operation with `context: self` so it resolves against the
# Context's config.
#
# Upstream also touches `config.log_regexp_timeout` (a Ruby-Regexp-timeout knob
# with no Crystal analog) — omitted; we exercise the same copy/override semantics
# with properties that DO exist (`default_model`, `default_embedding_model`).

# An offline fake provider: captures the config it was built with and the model
# it was asked to embed, so the entrypoint tests can prove `context: self` is
# threaded (the provider is resolved against the Context's config copy).
class ContextSpecFakeProvider < CrystalLLM::Provider
  class_property last_config : CrystalLLM::Configuration? = nil
  class_property last_embed_model : String? = nil

  def self.provider_name : String
    "ContextSpecFake"
  end

  def self.configuration_requirements : Array(String)
    [] of String
  end

  # Needed so `connection` (and thus `connection_for`) can build offline.
  def api_base : String
    "https://example.test"
  end

  def initialize(config : CrystalLLM::Configuration)
    super
    @@last_config = config
  end

  def embed(text : CrystalLLM::Provider::TextInput, model : String,
            dimensions : Int32? = nil) : CrystalLLM::Embedding
    @@last_embed_model = model
    CrystalLLM::Embedding.new(vectors: [0.1, 0.2] of Float64, model: model)
  end
end

CrystalLLM::Provider.register("ctx_fake", ContextSpecFakeProvider)

# Seeds fake-provider models so `Context#chat`/`#embed` resolve offline.
private def seed_ctx_models : Nil
  {"ctx-chat-model", "ctx-embed-model"}.each do |id|
    next if CrystalLLM::Models.instance.all.any?(&.id.== id)
    info = CrystalLLM::Model::Info.new(JSON.parse({
      "id"       => id,
      "name"     => id,
      "provider" => "ctx_fake",
      "type"     => "chat",
    }.to_json).as_h)
    CrystalLLM::Models.instance.all << info
  end
end

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

    describe "per-call entrypoints" do
      it "#chat builds a Chat resolved against the context's config" do
        seed_ctx_models
        ctx = CrystalLLM::Context.create(CrystalLLM.config) do |cfg|
          cfg.default_model = "ctx-chat-model"
        end

        chat = ctx.chat
        chat.should be_a(CrystalLLM::Chat)
        chat.model.id.should eq("ctx-chat-model")
      end

      it "#embed threads the context's config to the resolved provider" do
        seed_ctx_models
        ContextSpecFakeProvider.last_config = nil
        ContextSpecFakeProvider.last_embed_model = nil

        ctx = CrystalLLM::Context.create(CrystalLLM.config) do |cfg|
          cfg.default_embedding_model = "ctx-embed-model"
        end

        embedding = ctx.embed("hello")
        embedding.model.should eq("ctx-embed-model")
        # The provider was built with the Context's (copied) config, not the global.
        ContextSpecFakeProvider.last_embed_model.should eq("ctx-embed-model")
        ContextSpecFakeProvider.last_config.should be(ctx.config)
      end

      it "#connection_for exposes the provider's connection" do
        provider = ContextSpecFakeProvider.new(CrystalLLM.config)
        ctx = CrystalLLM::Context.new(CrystalLLM.config)
        ctx.connection_for(provider).should be(provider.connection)
      end
    end
  end
end
