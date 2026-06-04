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
