require "./spec_helper"
require "../src/crystal_llm/models"

module CrystalLLM
  describe Models do
    before_each do
      Models.reset!
    end

    describe ".all" do
      it "returns a non-empty array of Model::Info" do
        models = Models.all
        models.should_not be_empty
        models.first.should be_a(Model::Info)
      end

      it "loads roughly the expected number of models (>=1000)" do
        Models.all.size.should be >= 1000
      end
    end

    describe ".find" do
      it "finds a known model by id" do
        model = Models.find("gpt-4o")
        model.id.should eq("gpt-4o")
      end

      it "returns a Model::Info" do
        Models.find("gpt-4o").should be_a(Model::Info)
      end

      it "raises ModelNotFoundError for an unknown model id" do
        expect_raises(ModelNotFoundError, /Unknown model: "nonexistent-xyz"/) do
          Models.find("nonexistent-xyz")
        end
      end

      it "raises ModelNotFoundError with helpful refresh guidance" do
        expect_raises(ModelNotFoundError, /refresh/) do
          Models.find("nonexistent-xyz")
        end
      end

      it "finds a model when provider is specified" do
        model = Models.find("gpt-4o", "openai")
        model.id.should eq("gpt-4o")
        model.provider.should eq("openai")
      end

      it "raises ModelNotFoundError with provider context when provider given" do
        expect_raises(ModelNotFoundError, /for provider: "openai"/) do
          Models.find("nonexistent-xyz", "openai")
        end
      end

      it "resolves an alias to its concrete id (no provider)" do
        # claude-3-5-haiku -> claude-3-5-haiku-20241022 on anthropic
        model = Models.find("claude-3-5-haiku")
        model.id.should eq("claude-3-5-haiku-20241022")
      end

      it "resolves an alias for a specific provider" do
        model = Models.find("claude-3-5-haiku", "anthropic")
        model.id.should eq("claude-3-5-haiku-20241022")
        model.provider.should eq("anthropic")
      end

      it "prioritizes exact id over alias" do
        # gpt-4o exists exactly in the registry — should not redirect via alias
        model = Models.find("gpt-4o")
        model.id.should eq("gpt-4o")
      end
    end

    describe ".by_provider" do
      it "returns models for a given provider" do
        openai_models = Models.by_provider("openai")
        openai_models.should_not be_empty
        openai_models.all.each(&.provider.should(eq("openai")))
      end

      it "returns a Models instance" do
        Models.by_provider("anthropic").should be_a(Models)
      end

      it "returns an empty Models for an unknown provider" do
        Models.by_provider("unknown-provider-xyz").all.should be_empty
      end
    end

    describe ".by_family" do
      it "returns models for a known family" do
        # Pick whatever family the first model belongs to
        family = Models.all.first.family.to_s
        result = Models.by_family(family)
        result.should_not be_empty
        result.all.each(&.family.should(eq(family)))
      end
    end

    describe ".chat_models" do
      it "returns only chat models" do
        Models.chat_models.all.each do |info|
          info.type.should eq("chat")
        end
      end

      it "returns a non-empty Models" do
        Models.chat_models.should_not be_empty
      end
    end

    describe ".embedding_models" do
      it "returns only embedding-capable models" do
        Models.embedding_models.all.each do |info|
          (info.type == "embedding" || info.modalities.output.includes?("embeddings")).should be_true
        end
      end

      it "returns a non-empty Models" do
        Models.embedding_models.should_not be_empty
      end
    end

    describe ".audio_models" do
      it "returns only audio-capable models" do
        Models.audio_models.all.each do |info|
          (info.type == "audio" || info.modalities.output.includes?("audio")).should be_true
        end
      end
    end

    describe ".image_models" do
      it "returns only image-capable models" do
        Models.image_models.all.each do |info|
          (info.type == "image" || info.modalities.output.includes?("image")).should be_true
        end
      end
    end

    describe "#each / Enumerable" do
      it "supports select" do
        openai = Models.instance.select { |info| info.provider == "openai" }
        openai.should_not be_empty
        openai.each(&.provider.should(eq("openai")))
      end

      it "supports size" do
        Models.instance.size.should be >= 1000
      end

      it "supports map" do
        ids = Models.instance.map(&.id)
        ids.should_not be_empty
        ids.first.should be_a(String?)
      end
    end

    describe "filter_models (vertexai slash models excluded)" do
      it "excludes vertexai models with slash in id" do
        slash_model = Model::Info.build(
          id: "deepseek-ai/deepseek-v3.1-maas",
          provider: "vertexai",
          name: "DeepSeek"
        )
        clean_model = Model::Info.build(
          id: "gemini-2.5-flash",
          provider: "vertexai",
          name: "Gemini"
        )
        openrouter_slash = Model::Info.build(
          id: "deepseek-ai/deepseek-v3.1-maas",
          provider: "openrouter",
          name: "DeepSeek"
        )

        registry = Models.new([slash_model, clean_model, openrouter_slash])
        registry.by_provider("vertexai").all.map(&.id).should eq(["gemini-2.5-flash"])
        registry.by_provider("openrouter").all.map(&.id).should eq(["deepseek-ai/deepseek-v3.1-maas"])
      end
    end

    describe ".resolve" do
      it "resolves a known model id and returns Model::Info" do
        info = Models.resolve("gpt-4o")
        info.should be_a(Model::Info)
        info.id.should eq("gpt-4o")
      end

      it "resolves with provider specified" do
        info = Models.resolve("gpt-4o", provider: "openai")
        info.id.should eq("gpt-4o")
        info.provider.should eq("openai")
      end

      it "returns a synthetic default when assume_exists is true for unknown model" do
        info = Models.resolve("my-custom-model", provider: "openai", assume_exists: true)
        info.id.should eq("my-custom-model")
        info.provider.should eq("openai")
      end

      it "raises ArgumentError when assume_exists is true but no provider given" do
        expect_raises(ArgumentError, /Provider must be specified/) do
          Models.resolve("my-custom-model", assume_exists: true)
        end
      end
    end

    describe ".refresh!" do
      # Loads the small models.dev fixture instead of hitting the network.
      # Stubs existing_models_hook to return [] so refresh! starts from scratch
      # (no configured providers + empty existing → merged result == fixture models).
      fixture = File.read(File.join(__DIR__, "fixtures", "models_dev.json"))

      # CRITICAL (offline safety): `refresh!` calls `fetch_provider_models`, which
      # invokes `list_models` (REAL HTTP) on every registered + CONFIGURED provider.
      # In the full suite other specs register the real OpenAI provider and
      # always-configured fakes, so without this the suite would make live API
      # calls. Clear the registry around each test so the provider-fetch half is a
      # no-op and these tests stay fully offline; restore it afterward.
      saved_providers = Provider.providers.dup
      before_each do
        saved_providers = Provider.providers.dup
        Provider.providers.clear
      end
      after_each do
        Provider.providers.clear
        saved_providers.each { |slug, klass| Provider.register(slug, klass) }
      end

      it "replaces the registry with models parsed from the (stubbed) fetch" do
        Models.fetch_hook = -> { JSON.parse(fixture) }
        Models.existing_models_hook = -> { [] of Model::Info }
        Models.refresh!

        # A model only present in the fixture is now findable.
        model = Models.find("gpt-test-mini", "openai")
        model.id.should eq("gpt-test-mini")
        model.provider.should eq("openai")

        # The big embedded registry has been replaced by the small fixture set.
        Models.all.size.should be < 10
      ensure
        Models.reset!
      end

      it "maps models.dev provider keys to slugs and skips unmapped providers" do
        Models.fetch_hook = -> { JSON.parse(fixture) }
        Models.existing_models_hook = -> { [] of Model::Info }
        Models.refresh!

        Models.find("claude-test").provider.should eq("anthropic")
        # google->gemini style mapping is exercised via the map; the unmapped
        # provider's model must NOT be present.
        expect_raises(ModelNotFoundError) { Models.find("should-be-skipped") }
      ensure
        Models.reset!
      end

      it "derives capabilities and pricing from models.dev fields" do
        Models.fetch_hook = -> { JSON.parse(fixture) }
        Models.existing_models_hook = -> { [] of Model::Info }
        Models.refresh!

        model = Models.find("gpt-test-mini", "openai")
        model.function_calling?.should be_true
        model.structured_output?.should be_true
        model.supports_vision?.should be_true
        model.context_window.should eq(128000)
        model.max_output_tokens.should eq(16384)
        model.input_price_per_million.should eq(0.15)
        model.output_price_per_million.should eq(0.6)
      ensure
        Models.reset!
      end

      it "normalizes embedding model modalities to output ['embeddings']" do
        Models.fetch_hook = -> { JSON.parse(fixture) }
        Models.existing_models_hook = -> { [] of Model::Info }
        Models.refresh!

        embed = Models.find("text-embedding-test", "openai")
        embed.modalities.output.should eq(["embeddings"])
        embed.type.should eq("embedding")
      ensure
        Models.reset!
      end

      it "keeps the existing registry when the fetch fails" do
        original_size = Models.all.size
        Models.fetch_hook = -> { raise IO::Error.new("network down"); JSON.parse("{}") }
        Models.refresh!

        Models.all.size.should eq(original_size)
      ensure
        Models.reset!
      end

      # models.dev created_at precedence: release_date wins; else last_updated;
      # else nil (mirrors ruby_llm's `[release_date, last_updated].find(present?)`).
      it "derives created_at with release_date > last_updated > nil precedence" do
        Models.fetch_hook = -> { JSON.parse(fixture) }
        Models.existing_models_hook = -> { [] of Model::Info }
        Models.refresh!

        # gpt-test-mini has BOTH release_date (2025-01-15) and last_updated
        # (2025-02-01) — release_date wins.
        with_both = Models.find("gpt-test-mini", "openai")
        created = with_both.created_at
        created.should_not be_nil
        created.try(&.to_s("%Y-%m-%d")).should eq("2025-01-15")

        # claude-test has ONLY last_updated (2025-03-10) — it is used.
        only_updated = Models.find("claude-test", "anthropic")
        only_updated.created_at.try(&.to_s("%Y-%m-%d")).should eq("2025-03-10")

        # text-embedding-test has NEITHER — created_at is nil.
        Models.find("text-embedding-test", "openai").created_at.should be_nil
      ensure
        Models.reset!
      end
    end

    describe "#save_to_json / round-trip" do
      fixture = File.read(File.join(__DIR__, "fixtures", "models_dev.json"))

      it "writes the registry and reads it back identically" do
        Models.fetch_hook = -> { JSON.parse(fixture) }
        Models.refresh!

        path = File.tempname("models", ".json")
        begin
          Models.save_to_json(path)

          loaded = Models.read_from_json(path)
          loaded.map(&.id.to_s).sort!.should eq(Models.all.map(&.id.to_s).sort!)

          # A specific model survives the round-trip with its fields intact.
          reloaded = loaded.find! { |info| info.id == "gpt-test-mini" }
          reloaded.provider.should eq("openai")
          reloaded.context_window.should eq(128000)
          reloaded.input_price_per_million.should eq(0.15)
          reloaded.function_calling?.should be_true
        ensure
          File.delete(path) if File.exists?(path)
        end
      ensure
        Models.reset!
      end

      it "produces a non-empty JSON array on disk" do
        path = File.tempname("models", ".json")
        begin
          Models.save_to_json(path)
          content = File.read(path)
          parsed = JSON.parse(content)
          parsed.as_a.should_not be_empty
        ensure
          File.delete(path) if File.exists?(path)
        end
      ensure
        Models.reset!
      end
    end

    # Task 3a: Bedrock region-prefix resolution in Models.find
    describe "Bedrock region-prefix resolution in .find" do
      it "prefers the region-prefixed id when bedrock_region is set and a prefixed model exists" do
        meta_profile = {"inference_types" => JSON::Any.new([JSON::Any.new("INFERENCE_PROFILE")])}
        unprefixed = Model::Info.build(
          id: "anthropic.claude-3-5-sonnet-20241022-v2:0", provider: "bedrock",
          name: "unprefixed", metadata: meta_profile
        )
        prefixed = Model::Info.build(
          id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0", provider: "bedrock",
          name: "prefixed", metadata: meta_profile
        )

        registry = Models.new([unprefixed, prefixed])
        CrystalLLM.config.bedrock_region = "us-east-1"

        begin
          result = registry.find("anthropic.claude-3-5-sonnet-20241022-v2:0", "bedrock")
          result.id.should eq("us.anthropic.claude-3-5-sonnet-20241022-v2:0")
        ensure
          CrystalLLM.config.bedrock_region = nil
        end
      end

      it "falls back to the unprefixed id when no bedrock_region is configured" do
        meta = {"inference_types" => JSON::Any.new([JSON::Any.new("ON_DEMAND")])}
        unprefixed = Model::Info.build(
          id: "anthropic.claude-3-5-sonnet-20241022-v2:0", provider: "bedrock",
          name: "unprefixed", metadata: meta
        )
        prefixed = Model::Info.build(
          id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0", provider: "bedrock",
          name: "prefixed",
          metadata: {"inference_types" => JSON::Any.new([JSON::Any.new("INFERENCE_PROFILE")])}
        )

        registry = Models.new([unprefixed, prefixed])
        CrystalLLM.config.bedrock_region = nil

        result = registry.find("anthropic.claude-3-5-sonnet-20241022-v2:0", "bedrock")
        result.id.should eq("anthropic.claude-3-5-sonnet-20241022-v2:0")
      end

      it "falls back to the unprefixed id when no prefixed model exists in the registry" do
        meta = {"inference_types" => JSON::Any.new([JSON::Any.new("ON_DEMAND"), JSON::Any.new("INFERENCE_PROFILE")])}
        unprefixed = Model::Info.build(
          id: "anthropic.claude-3-5-sonnet-20241022-v2:0", provider: "bedrock",
          name: "unprefixed", metadata: meta
        )
        registry = Models.new([unprefixed])
        CrystalLLM.config.bedrock_region = "eu-west-1"

        begin
          result = registry.find("anthropic.claude-3-5-sonnet-20241022-v2:0", "bedrock")
          result.id.should eq("anthropic.claude-3-5-sonnet-20241022-v2:0")
        ensure
          CrystalLLM.config.bedrock_region = nil
        end
      end

      it "does not apply region prefix for ON_DEMAND-only models (no INFERENCE_PROFILE candidate)" do
        meta = {"inference_types" => JSON::Any.new([JSON::Any.new("ON_DEMAND")])}
        model = Model::Info.build(
          id: "anthropic.claude-small-test-v1:0", provider: "bedrock",
          name: "on-demand", metadata: meta
        )
        registry = Models.new([model])
        CrystalLLM.config.bedrock_region = "us-east-1"

        begin
          result = registry.find("anthropic.claude-small-test-v1:0", "bedrock")
          result.id.should eq("anthropic.claude-small-test-v1:0")
        ensure
          CrystalLLM.config.bedrock_region = nil
        end
      end
    end

    # Task 3b: load_from_database! with registerable db_source
    describe "#load_from_database!" do
      after_each { Models.reset! }

      it "raises NotImplementedError when db_source is not configured" do
        expect_raises(NotImplementedError, /Models.db_source is not configured/) do
          Models.instance.load_from_database!
        end
      end

      it "replaces the registry with rows from the configured db_source" do
        stub_model_a = Model::Info.build(id: "db-model-a", provider: "openai", name: "DB Model A")
        stub_model_b = Model::Info.build(id: "db-model-b", provider: "anthropic", name: "DB Model B")

        Models.db_source = -> { [stub_model_a, stub_model_b] of Model::Info }
        Models.instance.load_from_database!

        Models.all.map(&.id).should contain("db-model-a")
        Models.all.map(&.id).should contain("db-model-b")
        Models.all.size.should eq(2)
      end

      it "reset! clears the db_source hook" do
        Models.db_source = -> { [] of Model::Info }
        Models.reset!
        # After reset!, db_source is nil so NotImplementedError fires again.
        expect_raises(NotImplementedError) do
          Models.instance.load_from_database!
        end
      end
    end

    describe "Aliases" do
      it "resolves a known alias without provider" do
        Aliases.resolve("claude-3-5-haiku").should_not eq("claude-3-5-haiku")
      end

      it "resolves a known alias with a provider" do
        Aliases.resolve("claude-3-5-haiku", "anthropic").should eq("claude-3-5-haiku-20241022")
      end

      it "returns the original id when alias is unknown" do
        Aliases.resolve("definitely-not-an-alias-xyz").should eq("definitely-not-an-alias-xyz")
      end

      it "returns the original id when alias exists but provider has no entry" do
        Aliases.resolve("claude-3-5-haiku", "unknown-provider").should eq("claude-3-5-haiku")
      end
    end
  end
end
