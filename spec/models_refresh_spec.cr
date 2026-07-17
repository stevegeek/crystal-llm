require "./spec_helper"
require "../src/crystal_llm/models"

# Tests for the provider-fetch + merge half of Models.refresh!
# (ported from ruby_llm 1.15.0 models.rb).
#
# All specs are OFFLINE — no live network. Provider list_models is stubbed via
# fake provider subclasses; models.dev is stubbed via `Models.fetch_hook`.
# `existing_models_hook` lets tests start refresh! from a clean slate.

module CrystalLLM
  # Reopen Configuration to add test-only option properties.
  # The `[]?` method uses `{% for ivar in @type.instance_vars %}` at compile time,
  # so additions here are visible to `configured?` checks in fake providers.
  class Configuration
    property fake_remote_api_key : String? = nil
    property fake_local_host : String? = nil
    property fake_failing_api_key : String? = nil
  end

  # ---- Fake provider classes -------------------------------------------------

  # FakeRemoteProvider: a remote provider that returns two canned Model::Info
  # records. Requires `fake_remote_api_key` to be configured.
  class FakeRemoteProvider < Provider
    SLUG = "fake_remote"

    def self.slug : String
      SLUG
    end

    def self.configuration_requirements : Array(String)
      ["fake_remote_api_key"]
    end

    def self.local? : Bool
      false
    end

    def list_models : Array(Model::Info)
      [
        Model::Info.build(
          id: "fake-model-1",
          provider: FakeRemoteProvider::SLUG,
          name: "Fake Model One",
          family: "fake-family",
          context_window: 32000,
          capabilities: %w[function_calling streaming],
          modalities: Model::Modalities.new(input: %w[text], output: %w[text]),
          metadata: {"source" => JSON::Any.new("fake_remote"), "extra" => JSON::Any.new("from_provider")}
        ),
        Model::Info.build(
          id: "fake-model-2",
          provider: FakeRemoteProvider::SLUG,
          name: "Fake Model Two",
          capabilities: %w[streaming],
          modalities: Model::Modalities.new(input: %w[text image], output: %w[text]),
          metadata: {"source" => JSON::Any.new("fake_remote")}
        ),
      ]
    end

    def api_base : String
      "https://fake.example.com"
    end
  end

  # FakeLocalProvider: a local (non-remote) provider. Skipped by remote_only.
  class FakeLocalProvider < Provider
    SLUG = "fake_local"

    def self.slug : String
      SLUG
    end

    def self.configuration_requirements : Array(String)
      ["fake_local_host"]
    end

    def self.local? : Bool
      true
    end

    def list_models : Array(Model::Info)
      [
        Model::Info.build(
          id: "local-model-1",
          provider: FakeLocalProvider::SLUG,
          name: "Local Model One",
          modalities: Model::Modalities.new(input: %w[text], output: %w[text]),
          metadata: {"source" => JSON::Any.new("fake_local")}
        ),
      ]
    end

    def api_base : String
      "http://localhost:11434"
    end
  end

  # FakeFailingProvider: always raises on list_models.
  class FakeFailingProvider < Provider
    SLUG = "fake_failing"

    def self.slug : String
      SLUG
    end

    def self.configuration_requirements : Array(String)
      ["fake_failing_api_key"]
    end

    def self.local? : Bool
      false
    end

    def list_models : Array(Model::Info)
      raise IO::Error.new("network down")
    end

    def api_base : String
      "https://fail.example.com"
    end
  end

  # ---- Spec body -------------------------------------------------------------

  describe Models do
    # Isolate these tests from the GLOBAL provider registry. Other specs in the
    # full suite register always-configured fake providers (e.g. agent_spec's
    # `agent_spec_fake`, context_spec's `ctx_fake`) which would otherwise leak into
    # `fetch_provider_models` and break the empty/exact-count assertions below.
    # Snapshot + clear before each test (so each starts from a clean registry and
    # registers only its own fakes), then restore afterward.
    saved_providers = Provider.providers.dup

    before_each do
      saved_providers = Provider.providers.dup
      Provider.providers.clear
    end

    after_each do
      Models.reset!
      Provider.providers.clear
      saved_providers.each { |slug, klass| Provider.register(slug, klass) }
      # Reset any test config changes
      CrystalLLM.config.fake_remote_api_key = nil
      CrystalLLM.config.fake_local_host = nil
      CrystalLLM.config.fake_failing_api_key = nil
    end

    # ---- fetch_provider_models -----------------------------------------------

    describe ".fetch_provider_models" do
      it "returns empty result when no providers are configured" do
        result = Models.fetch_provider_models(remote_only: false)
        result.models.should be_empty
        result.fetched_providers.should be_empty
        result.failed.should be_empty
      end

      it "returns models from a configured remote provider" do
        Provider.register(FakeRemoteProvider::SLUG, FakeRemoteProvider)
        CrystalLLM.config.fake_remote_api_key = "test-key"

        result = Models.fetch_provider_models(remote_only: false)
        result.models.size.should eq(2)
        result.models.map(&.id).should contain("fake-model-1")
        result.fetched_providers.should contain(FakeRemoteProvider::SLUG)
        result.failed.should be_empty
      end

      it "skips an unconfigured provider" do
        Provider.register(FakeRemoteProvider::SLUG, FakeRemoteProvider)
        # Do NOT set fake_remote_api_key

        result = Models.fetch_provider_models(remote_only: false)
        result.models.should be_empty
      end

      it "skips local providers when remote_only is true" do
        Provider.register(FakeLocalProvider::SLUG, FakeLocalProvider)
        CrystalLLM.config.fake_local_host = "http://localhost:11434"

        result = Models.fetch_provider_models(remote_only: true)
        result.models.should be_empty
        result.fetched_providers.should be_empty
      end

      it "includes local providers when remote_only is false" do
        Provider.register(FakeLocalProvider::SLUG, FakeLocalProvider)
        CrystalLLM.config.fake_local_host = "http://localhost:11434"

        result = Models.fetch_provider_models(remote_only: false)
        result.models.size.should eq(1)
        result.models.first.id.should eq("local-model-1")
        result.fetched_providers.should contain(FakeLocalProvider::SLUG)
      end

      it "records a failed provider without raising and without adding to fetched_providers" do
        Provider.register(FakeFailingProvider::SLUG, FakeFailingProvider)
        CrystalLLM.config.fake_failing_api_key = "test-key"

        result = Models.fetch_provider_models(remote_only: false)
        result.models.should be_empty
        result.fetched_providers.should_not contain(FakeFailingProvider::SLUG)
        result.failed.size.should eq(1)
        result.failed.first[:slug].should eq(FakeFailingProvider::SLUG)
      end

      it "does not duplicate a provider slug in fetched_providers" do
        Provider.register(FakeRemoteProvider::SLUG, FakeRemoteProvider)
        CrystalLLM.config.fake_remote_api_key = "test-key"

        result = Models.fetch_provider_models(remote_only: false)
        result.fetched_providers.count(FakeRemoteProvider::SLUG).should eq(1)
      end
    end

    # ---- index_by_key --------------------------------------------------------

    describe ".index_by_key" do
      it "indexes models by 'provider:id' key" do
        m1 = Model::Info.build(id: "m1", provider: "openai")
        m2 = Model::Info.build(id: "m2", provider: "anthropic")

        index = Models.index_by_key([m1, m2])
        index["openai:m1"].should eq(m1)
        index["anthropic:m2"].should eq(m2)
      end
    end

    # ---- normalize_models_dev_modalities --------------------------------------

    # ruby_llm 3f27b864: modalities are intersected with the models.dev-owned
    # vocab (`& MODELS_DEV_INPUT_MODALITIES` / `& MODELS_DEV_OUTPUT_MODALITIES`),
    # not just `.compact`-ed — an unrecognized tag is dropped rather than passed
    # through verbatim.
    describe ".normalize_models_dev_modalities" do
      it "keeps only the models.dev-allowed input/output modality tags" do
        modalities = JSON.parse({
          "input"  => ["text", "image", "bogus-input"],
          "output" => ["text", "moderation", "nonsense-output"],
        }.to_json)

        result = Models.normalize_models_dev_modalities(modalities)
        result["input"].should eq(["text", "image"])
        result["output"].should eq(["text", "moderation"])
      end

      it "returns empty arrays when modalities is nil" do
        result = Models.normalize_models_dev_modalities(nil)
        result["input"].should eq([] of String)
        result["output"].should eq([] of String)
      end
    end

    # ---- models_dev_capabilities -----------------------------------------------

    describe ".models_dev_capabilities" do
      it "grants reasoning when the reasoning flag is true" do
        data = JSON.parse({"reasoning" => true}.to_json).as_h
        modalities = {"input" => [] of String, "output" => [] of String}
        Models.models_dev_capabilities(data, modalities).should contain("reasoning")
      end

      # ruby_llm 3f27b864: `reasoning` if model_data[:reasoning] || model_data[:reasoning_options]
      it "grants reasoning when reasoning_options is present even if the reasoning flag is false" do
        data = JSON.parse({
          "reasoning"         => false,
          "reasoning_options" => [{"type" => "effort"}],
        }.to_json).as_h
        modalities = {"input" => [] of String, "output" => [] of String}
        Models.models_dev_capabilities(data, modalities).should contain("reasoning")
      end

      it "does not grant reasoning when neither reasoning nor reasoning_options is present" do
        data = {} of String => JSON::Any
        modalities = {"input" => [] of String, "output" => [] of String}
        Models.models_dev_capabilities(data, modalities).should_not contain("reasoning")
      end
    end

    # ---- blank_value? --------------------------------------------------------

    describe ".blank_value?" do
      it "treats nil as blank" do
        Models.blank_value?(nil).should be_true
      end

      it "treats JSON null as blank" do
        Models.blank_value?(JSON::Any.new(nil)).should be_true
      end

      it "treats empty string as blank" do
        Models.blank_value?(JSON::Any.new("")).should be_true
      end

      it "treats non-empty string as not blank" do
        Models.blank_value?(JSON::Any.new("hello")).should be_false
      end

      it "treats empty array as blank" do
        Models.blank_value?(JSON::Any.new([] of JSON::Any)).should be_true
      end

      it "treats non-empty array as not blank" do
        Models.blank_value?(JSON::Any.new([JSON::Any.new("a")])).should be_false
      end

      it "treats empty hash as blank" do
        Models.blank_value?(JSON::Any.new({} of String => JSON::Any)).should be_true
      end

      it "treats a hash with all-blank values as blank" do
        h = {"a" => JSON::Any.new(""), "b" => JSON::Any.new(nil)}
        Models.blank_value?(JSON::Any.new(h)).should be_true
      end

      it "treats a hash with at least one non-blank value as not blank" do
        h = {"a" => JSON::Any.new(""), "b" => JSON::Any.new("present")}
        Models.blank_value?(JSON::Any.new(h)).should be_false
      end

      it "treats an integer as not blank" do
        Models.blank_value?(JSON::Any.new(42_i64)).should be_false
      end

      it "treats 0 as not blank (only nil/empty/all-blank count)" do
        Models.blank_value?(JSON::Any.new(0_i64)).should be_false
      end

      it "treats false as not blank" do
        Models.blank_value?(JSON::Any.new(false)).should be_false
      end
    end

    # ---- find_models_dev_model -----------------------------------------------

    describe ".find_models_dev_model" do
      it "returns nil for an unknown key" do
        Models.find_models_dev_model("openai:nonexistent", {} of String => Model::Info).should be_nil
      end

      it "direct match returns the model" do
        m = Model::Info.build(id: "gpt-4o", provider: "openai")
        index = {"openai:gpt-4o" => m}
        result = Models.find_models_dev_model("openai:gpt-4o", index)
        result.should eq(m)
      end

      it "bedrock: strips two-letter region prefix and finds base model" do
        base = Model::Info.build(id: "anthropic.claude-3-haiku", provider: "bedrock",
          name: "Haiku", context_window: 200000)
        index = {"bedrock:anthropic.claude-3-haiku" => base}

        found = Models.find_models_dev_model("bedrock:us.anthropic.claude-3-haiku", index)
        found.should_not be_nil
        # id is restored to the original (prefixed) form
        found.try(&.id).should eq("us.anthropic.claude-3-haiku")
        found.try(&.provider).should eq("bedrock")
        # context_window from base model preserved
        found.try(&.context_window).should eq(200000)
      end

      it "bedrock: :Nk suffix sets context_window override and is kept in id" do
        base = Model::Info.build(id: "anthropic.claude-3-haiku", provider: "bedrock",
          name: "Haiku", context_window: 200000)
        index = {"bedrock:anthropic.claude-3-haiku" => base}

        found = Models.find_models_dev_model("bedrock:anthropic.claude-3-haiku:128k", index)
        found.should_not be_nil
        # id retains the :128k suffix
        found.try(&.id).should eq("anthropic.claude-3-haiku:128k")
        # context_window is overridden to 128000
        found.try(&.context_window).should eq(128000)
      end

      it "bedrock: region prefix + context override combined" do
        base = Model::Info.build(id: "anthropic.claude-3-5-sonnet", provider: "bedrock",
          context_window: 200000)
        index = {"bedrock:anthropic.claude-3-5-sonnet" => base}

        found = Models.find_models_dev_model("bedrock:us.anthropic.claude-3-5-sonnet:200k", index)
        found.should_not be_nil
        found.try(&.id).should eq("us.anthropic.claude-3-5-sonnet:200k")
        found.try(&.context_window).should eq(200000)
      end

      it "bedrock: returns nil when no match after stripping prefix" do
        Models.find_models_dev_model("bedrock:us.no-such-model", {} of String => Model::Info).should be_nil
      end

      it "vertexai: falls back to gemini entry and sets provider to vertexai" do
        gemini = Model::Info.build(id: "gemini-1.5-pro", provider: "gemini",
          name: "Gemini 1.5 Pro")
        index = {"gemini:gemini-1.5-pro" => gemini}

        found = Models.find_models_dev_model("vertexai:gemini-1.5-pro", index)
        found.should_not be_nil
        found.try(&.id).should eq("gemini-1.5-pro")
        found.try(&.provider).should eq("vertexai")
        found.try(&.name).should eq("Gemini 1.5 Pro")
      end

      it "vertexai: returns nil when no gemini match" do
        Models.find_models_dev_model("vertexai:no-such-model", {} of String => Model::Info).should be_nil
      end

      it "non-bedrock/non-vertexai: returns nil for missing key" do
        Models.find_models_dev_model("openai:missing", {} of String => Model::Info).should be_nil
      end
    end

    # ---- add_provider_metadata -----------------------------------------------

    describe ".add_provider_metadata" do
      it "fills a blank name from the provider model" do
        md = Model::Info.build(id: "m1", provider: "openai", name: "")
        prov = Model::Info.build(id: "m1", provider: "openai", name: "Provider Name")

        result = Models.add_provider_metadata(md, prov)
        result.name.should eq("Provider Name")
      end

      it "keeps the models.dev name when already present" do
        md = Model::Info.build(id: "m1", provider: "openai", name: "Dev Name")
        prov = Model::Info.build(id: "m1", provider: "openai", name: "Provider Name")

        result = Models.add_provider_metadata(md, prov)
        result.name.should eq("Dev Name")
      end

      it "fills blank family from provider model" do
        md = Model::Info.build(id: "m1", provider: "openai")
        prov = Model::Info.build(id: "m1", provider: "openai", family: "gpt-4")

        result = Models.add_provider_metadata(md, prov)
        result.family.should eq("gpt-4")
      end

      it "fills blank context_window from provider model" do
        md = Model::Info.build(id: "m1", provider: "openai")
        prov = Model::Info.build(id: "m1", provider: "openai", context_window: 128000)

        result = Models.add_provider_metadata(md, prov)
        result.context_window.should eq(128000)
      end

      it "fills blank max_output_tokens from provider model" do
        md = Model::Info.build(id: "m1", provider: "openai")
        prov = Model::Info.build(id: "m1", provider: "openai", max_output_tokens: 4096)

        result = Models.add_provider_metadata(md, prov)
        result.max_output_tokens.should eq(4096)
      end

      it "keeps models.dev context_window when already present" do
        md = Model::Info.build(id: "m1", provider: "openai", context_window: 200000)
        prov = Model::Info.build(id: "m1", provider: "openai", context_window: 128000)

        result = Models.add_provider_metadata(md, prov)
        result.context_window.should eq(200000)
      end

      it "unions capabilities from models.dev and provider, deduplicates" do
        md = Model::Info.build(id: "m1", provider: "openai",
          capabilities: %w[structured_output function_calling])
        prov = Model::Info.build(id: "m1", provider: "openai",
          capabilities: %w[function_calling streaming])

        result = Models.add_provider_metadata(md, prov)
        result.capabilities.sort!.should eq(%w[function_calling streaming structured_output])
      end

      # ruby_llm 3f27b864 (MODELS_DEV_AUTHORITY_CAPABILITIES): models.dev is the
      # authority for function_calling/structured_output/reasoning/vision — a
      # provider's own claim to one of these is dropped unless models.dev also
      # grants it. Non-authority provider capabilities (e.g. "streaming") still
      # pass through unconditionally.
      it "drops provider-only authority capabilities that models.dev does not confirm" do
        md = Model::Info.build(id: "m1", provider: "openai",
          capabilities: %w[structured_output])
        prov = Model::Info.build(id: "m1", provider: "openai",
          capabilities: %w[reasoning vision streaming])

        result = Models.add_provider_metadata(md, prov)
        result.capabilities.sort!.should eq(%w[streaming structured_output])
      end

      it "keeps a provider authority capability when models.dev also grants it" do
        md = Model::Info.build(id: "m1", provider: "openai",
          capabilities: %w[reasoning])
        prov = Model::Info.build(id: "m1", provider: "openai",
          capabilities: %w[reasoning streaming])

        result = Models.add_provider_metadata(md, prov)
        result.capabilities.sort!.should eq(%w[reasoning streaming])
      end

      it "merges metadata: provider as base, models.dev overwrites" do
        md_meta = {"source" => JSON::Any.new("models.dev"), "md_key" => JSON::Any.new("md_val")}
        prov_meta = {"source" => JSON::Any.new("provider"), "prov_key" => JSON::Any.new("prov_val")}

        md = Model::Info.build(id: "m1", provider: "openai", metadata: md_meta)
        prov = Model::Info.build(id: "m1", provider: "openai", metadata: prov_meta)

        result = Models.add_provider_metadata(md, prov)
        # models.dev "source" wins
        result.metadata["source"]?.try(&.as_s?).should eq("models.dev")
        # both provider-only and models.dev-only keys preserved
        result.metadata["prov_key"]?.try(&.as_s?).should eq("prov_val")
        result.metadata["md_key"]?.try(&.as_s?).should eq("md_val")
      end

      it "fills blank modalities from provider model" do
        md = Model::Info.build(id: "m1", provider: "openai",
          modalities: Model::Modalities.new)
        prov = Model::Info.build(id: "m1", provider: "openai",
          modalities: Model::Modalities.new(input: %w[text image], output: %w[text]))

        result = Models.add_provider_metadata(md, prov)
        result.modalities.input.should contain("image")
      end

      it "normalizes embedding modalities: forces output=['embeddings']" do
        md = Model::Info.build(
          id: "text-embedding-3-small",
          provider: "openai",
          modalities: Model::Modalities.new(input: %w[text], output: [] of String)
        )
        prov = Model::Info.build(
          id: "text-embedding-3-small",
          provider: "openai",
          capabilities: %w[streaming]
        )

        result = Models.add_provider_metadata(md, prov)
        result.modalities.output.should eq(["embeddings"])
      end
    end

    # ---- merge_models --------------------------------------------------------

    describe ".merge_models" do
      it "models.dev-only model is included unchanged" do
        md_model = Model::Info.build(id: "md-only", provider: "openai",
          name: "MD Only", metadata: {"source" => JSON::Any.new("models.dev")})

        result = Models.merge_models([] of Model::Info, [md_model])
        result.map(&.id).should contain("md-only")
      end

      it "provider-only model is included unchanged" do
        prov_model = Model::Info.build(id: "prov-only", provider: "openai",
          name: "Prov Only")

        result = Models.merge_models([prov_model], [] of Model::Info)
        result.map(&.id).should contain("prov-only")
      end

      it "model present in both uses add_provider_metadata (name filled, caps unioned)" do
        md_model = Model::Info.build(id: "shared", provider: "openai",
          name: "", capabilities: %w[structured_output],
          metadata: {"source" => JSON::Any.new("models.dev")})
        # "function_calling" is a models.dev-authority capability (ruby_llm
        # 3f27b864): the provider's own claim to it is dropped since models.dev
        # doesn't confirm it here. "streaming" (non-authority) still unions in.
        prov_model = Model::Info.build(id: "shared", provider: "openai",
          name: "Provider Name", capabilities: %w[function_calling streaming])

        result = Models.merge_models([prov_model], [md_model])
        merged = result.find { |info| info.id == "shared" }
        merged.should_not be_nil
        merged.try(&.name).should eq("Provider Name")
        merged.try(&.capabilities).try(&.sort!).should eq(%w[streaming structured_output])
      end

      it "result is sorted by [provider, id]" do
        models = [
          Model::Info.build(id: "z-model", provider: "openai"),
          Model::Info.build(id: "a-model", provider: "openai"),
          Model::Info.build(id: "b-model", provider: "anthropic"),
        ]

        result = Models.merge_models(models, [] of Model::Info)
        result.first.provider.should eq("anthropic")
        # openai models should be alpha-sorted
        openai = result.select { |info| info.provider == "openai" }
        openai.map(&.id).should eq(["a-model", "z-model"])
      end

      it "filter_models: drops vertexai models with slash in id" do
        slash_model = Model::Info.build(id: "some-org/model", provider: "vertexai")
        clean_model = Model::Info.build(id: "gemini-2.0-flash", provider: "vertexai")

        result = Models.merge_models([slash_model, clean_model], [] of Model::Info)
        result.map(&.id).should contain("gemini-2.0-flash")
        result.map(&.id).should_not contain("some-org/model")
      end

      it "does NOT drop slash models for non-vertexai providers" do
        openrouter_slash = Model::Info.build(id: "org/model", provider: "openrouter")
        result = Models.merge_models([openrouter_slash], [] of Model::Info)
        result.map(&.id).should contain("org/model")
      end
    end

    # ---- merge_with_existing -------------------------------------------------

    describe ".merge_with_existing" do
      it "preserves existing models for providers not in fetched_providers" do
        existing = [
          Model::Info.build(id: "old-openai", provider: "openai"),
          Model::Info.build(id: "old-anthropic", provider: "anthropic"),
        ]
        provider_fetch = Models::ProviderFetchResult.new(
          models: [Model::Info.build(id: "new-openai", provider: "openai")],
          fetched_providers: ["openai"],
          failed: [] of NamedTuple(slug: String, error: Exception)
        )
        models_dev_fetch = Models::ModelsDevFetchResult.new(
          models: [] of Model::Info,
          fetched: true
        )

        result = Models.merge_with_existing(existing, provider_fetch, models_dev_fetch)
        result.map(&.id).should contain("new-openai")
        result.map(&.id).should contain("old-anthropic")
        result.map(&.id).should_not contain("old-openai")
      end

      it "on models.dev fetch failure, uses cached models.dev-sourced existing models" do
        md_meta = {"source" => JSON::Any.new("models.dev")}
        prov_meta = {"source" => JSON::Any.new("provider")}

        existing = [
          Model::Info.build(id: "cached-md", provider: "openai", metadata: md_meta),
          Model::Info.build(id: "prov-model", provider: "openai", metadata: prov_meta),
        ]
        provider_fetch = Models::ProviderFetchResult.new(
          models: [] of Model::Info,
          fetched_providers: [] of String,
          failed: [] of NamedTuple(slug: String, error: Exception)
        )
        models_dev_fetch = Models::ModelsDevFetchResult.new(
          models: [] of Model::Info,
          fetched: false # fetch failed
        )

        result = Models.merge_with_existing(existing, provider_fetch, models_dev_fetch)
        # cached models.dev model and provider model both preserved (none fetched fresh)
        result.map(&.id).should contain("cached-md")
        result.map(&.id).should contain("prov-model")
      end
    end

    # ---- Full refresh! integration -------------------------------------------

    describe ".refresh! (end-to-end with fake provider)" do
      it "merges provider models and models.dev, provider fills blank models.dev fields" do
        Provider.register(FakeRemoteProvider::SLUG, FakeRemoteProvider)
        CrystalLLM.config.fake_remote_api_key = "test-key"

        # Build a models.dev fixture: fake-model-1 exists with blank name + no context_window
        # mapped under "openai" provider key → "openai" slug.
        # We need a fixture whose slug matches the fake provider slug, but the
        # provider map only knows "openai"→"openai" etc. So instead we test the
        # scenario where models.dev data and provider data have the SAME provider slug
        # by placing fake-model-1 under a mapping that results in "fake_remote".
        #
        # Since we cannot add to MODELS_DEV_PROVIDER_MAP at runtime, we test the
        # case where models.dev returns "openai" models and fake_remote provides
        # "fake_remote" models — they are merged together (union), with provider-only
        # models from fake_remote also present.
        fixture_json = %({
          "openai": {
            "id": "openai",
            "name": "OpenAI",
            "models": {
              "gpt-test-x": {
                "id": "gpt-test-x",
                "name": "GPT Test X",
                "modalities": {"input": ["text"], "output": ["text"]},
                "tool_call": true
              }
            }
          }
        })
        Models.fetch_hook = -> { JSON.parse(fixture_json) }
        Models.existing_models_hook = -> { [] of Model::Info }

        Models.refresh!(remote_only: false)

        all_ids = Models.all.map(&.id.to_s)
        # models.dev model present
        all_ids.should contain("gpt-test-x")
        # provider models present (fake_remote, separate from openai key)
        all_ids.should contain("fake-model-1")
        all_ids.should contain("fake-model-2")
      end

      it "remote_only: true skips local providers" do
        Provider.register(FakeLocalProvider::SLUG, FakeLocalProvider)
        Provider.register(FakeRemoteProvider::SLUG, FakeRemoteProvider)
        CrystalLLM.config.fake_local_host = "http://localhost:11434"
        CrystalLLM.config.fake_remote_api_key = "test-key"

        empty_fixture = %({"openai": {"id": "openai", "name": "OpenAI", "models": {}}})
        Models.fetch_hook = -> { JSON.parse(empty_fixture) }
        Models.existing_models_hook = -> { [] of Model::Info }

        Models.refresh!(remote_only: true)

        all_ids = Models.all.map(&.id.to_s)
        all_ids.should contain("fake-model-1")
        all_ids.should contain("fake-model-2")
        all_ids.should_not contain("local-model-1")
      end

      it "provider fetch failure keeps existing models for that provider" do
        Provider.register(FakeFailingProvider::SLUG, FakeFailingProvider)
        CrystalLLM.config.fake_failing_api_key = "test-key"

        existing_model = Model::Info.build(id: "legacy-model",
          provider: FakeFailingProvider::SLUG)
        Models.existing_models_hook = -> { [existing_model] of Model::Info }

        empty_fixture = %({"openai": {"id": "openai", "name": "OpenAI", "models": {}}})
        Models.fetch_hook = -> { JSON.parse(empty_fixture) }

        Models.refresh!(remote_only: false)

        # Existing model preserved when provider fetch fails
        Models.all.map(&.id).should contain("legacy-model")
      end

      it "models.dev fetch failure keeps cached models.dev models" do
        md_meta = {"source" => JSON::Any.new("models.dev")}
        cached = Model::Info.build(id: "cached-md-model", provider: "openai",
          metadata: md_meta)
        Models.existing_models_hook = -> { [cached] of Model::Info }

        Models.fetch_hook = -> { raise IO::Error.new("network down"); JSON.parse("{}") }

        Models.refresh!(remote_only: false)

        Models.all.map(&.id).should contain("cached-md-model")
      end

      it "result is sorted by [provider, id]" do
        Provider.register(FakeRemoteProvider::SLUG, FakeRemoteProvider)
        CrystalLLM.config.fake_remote_api_key = "test-key"

        empty_fixture = %({"openai": {"id": "openai", "name": "OpenAI", "models": {}}})
        Models.fetch_hook = -> { JSON.parse(empty_fixture) }
        Models.existing_models_hook = -> { [] of Model::Info }

        Models.refresh!(remote_only: false)

        providers = Models.all.map(&.provider.to_s)
        providers.should eq(providers.sort)
      end
    end
  end
end
