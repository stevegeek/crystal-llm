require "./spec_helper"
require "../src/crystal_llm/provider"

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

  describe "#parse_error" do
    it "digs the message out of provider error bodies" do
      config = CrystalLLM::Configuration.new
      config.http_proxy = "set"
      provider = ProviderSpecDummy.new(config)
      provider.parse_error(build_response(400, %({"error":{"message":"boom"}}))).should eq("boom")
      provider.parse_error(build_response(400, %({"error":"flat"}))).should eq("flat")
      provider.parse_error(build_response(400, "")).should be_nil
    end
  end
end
