require "./spec_helper"
require "../src/crystal_llm/provider"
require "../src/crystal_llm/provider_completion"
require "../src/crystal_llm/providers/anthropic"
require "../src/crystal_llm/providers/openai"
require "../src/crystal_llm/providers/azure"
require "../src/crystal_llm/providers/gemini"
require "../src/crystal_llm/providers/mistral"
require "../src/crystal_llm/providers/deepseek"
require "../src/crystal_llm/providers/xai"
require "../src/crystal_llm/providers/perplexity"
require "../src/crystal_llm/providers/openrouter"
require "../src/crystal_llm/providers/ollama"
require "../src/crystal_llm/providers/vertexai"
require "../src/crystal_llm/providers/bedrock"
require "../src/crystal_llm/providers/gpustack"

# The built-in provider slugs expected to be registered in a full test run.
# Used by the schema-invariant meta-tests to skip spec-local dummy providers.
REAL_PROVIDER_SLUGS = %w[
  openai anthropic azure gemini mistral deepseek xai perplexity
  openrouter ollama vertexai bedrock gpustack
]

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

# A minimal concrete provider. http_proxy (a String? config option) stands in for
# an api-key requirement until real provider api-key options are registered.
class ProviderSpecDummy < CrystalLLM::Provider
  def self.configuration_requirements : Array(String)
    ["http_proxy"]
  end

  def api_base : String
    "https://example.test/v1"
  end
end

describe CrystalLLM::Provider do
  describe "registry" do
    it "registers and resolves providers by name" do
      CrystalLLM::Provider.register("provider_spec_dummy", ProviderSpecDummy)
      CrystalLLM::Provider.resolve("provider_spec_dummy").should eq(ProviderSpecDummy)
      CrystalLLM::Provider.resolve("nope").should be_nil
    end
  end

  describe "locality / model resolution (ruby_llm parity)" do
    it "defaults to remote (class + instance)" do
      ProviderSpecDummy.local?.should be_false
      ProviderSpecDummy.remote?.should be_true
      ProviderSpecDummy.assume_models_exist?.should be_false

      config = CrystalLLM::Configuration.new
      config.http_proxy = "set"
      provider = ProviderSpecDummy.new(config)
      provider.local?.should be_false
      provider.remote?.should be_true
      provider.assume_models_exist?.should be_false
    end

    it "resolves a provider class for a model via Provider.for" do
      CrystalLLM::Provider.for("claude-3-5-haiku-20241022").should eq(CrystalLLM::Providers::Anthropic)
    end

    it "partitions the registry into local/remote/configured-remote providers" do
      CrystalLLM::Provider.register("provider_spec_dummy", ProviderSpecDummy)
      CrystalLLM::Provider.remote_providers.should contain(ProviderSpecDummy)
      CrystalLLM::Provider.local_providers.should_not contain(ProviderSpecDummy)

      config = CrystalLLM::Configuration.new
      CrystalLLM::Provider.configured_remote_providers(config).should_not contain(ProviderSpecDummy)
      config.http_proxy = "set"
      CrystalLLM::Provider.configured_remote_providers(config).should contain(ProviderSpecDummy)
    end
  end

  describe "configuration" do
    it "reports configured? from configuration_requirements" do
      config = CrystalLLM::Configuration.new
      ProviderSpecDummy.configured?(config).should be_false
      config.http_proxy = "set"
      ProviderSpecDummy.configured?(config).should be_true
    end

    it "raises ConfigurationError when constructed unconfigured" do
      config = CrystalLLM::Configuration.new
      expect_raises(CrystalLLM::ConfigurationError, "Missing configuration") do
        ProviderSpecDummy.new(config)
      end
    end

    it "constructs when configured" do
      config = CrystalLLM::Configuration.new
      config.http_proxy = "set"
      ProviderSpecDummy.new(config).should be_a(CrystalLLM::Provider)
    end
  end

  describe "#sign_headers (default hook)" do
    it "returns no extra headers (signing is opt-in per provider)" do
      config = CrystalLLM::Configuration.new
      config.http_proxy = "set"
      provider = ProviderSpecDummy.new(config)
      provider.sign_headers("POST", "/v1/chat", "{}").should be_empty
    end
  end

  # Meta-test: for every REAL registered provider, configuration_requirements ⊆
  # configuration_options. Mirrors ruby_llm's provider_spec.rb "keeps requirements as
  # a subset of declared configuration options". This catches a class where
  # `configuration_requirements` lists a key that `configuration_options` forgot to
  # declare (a drift bug).
  # Spec-local dummy providers (ProviderSpecDummy etc.) are excluded: they are test
  # scaffolding that piggybacks on the global registry and is not expected to have a
  # fully-declared options surface.
  describe "provider configuration schema invariant" do
    it "configuration_requirements is always a subset of configuration_options for every real provider" do
      REAL_PROVIDER_SLUGS.each do |name|
        provider_class = CrystalLLM::Provider.resolve(name)
        next unless provider_class # provider may not be registered in this run

        reqs = provider_class.configuration_requirements
        opts = provider_class.configuration_options
        missing = reqs.reject { |req| opts.includes?(req) }
        missing.should eq([] of String),
          "#{name} (#{provider_class}): configuration_requirements has keys not in " \
          "configuration_options: #{missing.inspect}"
      end
    end

    it "every configuration_requirement is a known Configuration option" do
      # Belt-and-suspenders: also check the requirements are real Configuration ivars
      # (not just declared in configuration_options but forgotten to add as properties).
      config_options = CrystalLLM::Configuration.options
      REAL_PROVIDER_SLUGS.each do |name|
        provider_class = CrystalLLM::Provider.resolve(name)
        next unless provider_class

        provider_class.configuration_requirements.each do |req|
          config_options.should contain(req),
            "#{name}: configuration_requirements includes #{req.inspect} which is not " \
            "a property on Configuration"
        end
      end
    end
  end

  describe "#parse_error" do
    it "digs the message out of provider error bodies" do
      config = CrystalLLM::Configuration.new
      config.http_proxy = "set"
      provider = ProviderSpecDummy.new(config)
      provider.parse_error(build_response(400, %({"error":{"message":"boom"}}))).should eq("boom")
      provider.parse_error(build_response(400, %({"error":"flat"}))).should eq("flat")
      provider.parse_error(build_response(400, "")).should be_nil
    end

    # Regression (BUG 13): the array branch must join with ". " and render a
    # nil/missing message as "" (ruby_llm's `.map { ... }.join('. ')`), NOT drop
    # the entry. `compact_map` dropped nils, collapsing the segment count.
    it "renders a nil message in an error array as an empty segment (not dropped)" do
      config = CrystalLLM::Configuration.new
      config.http_proxy = "set"
      provider = ProviderSpecDummy.new(config)

      body = %([{"error":"first"},{"no_error":true},{"error":{"message":"third"}}])
      provider.parse_error(build_response(400, body)).should eq("first. . third")
    end
  end
end
