require "../spec_helper"
require "../../src/crystal_llm/providers/azure"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

private def configured_azure(base : String = "https://my-resource.openai.azure.com") : CrystalLLM::Providers::Azure
  config = CrystalLLM::Configuration.new
  config.azure_api_key = "test"
  config.azure_api_base = base
  CrystalLLM::Providers::Azure.new(config)
end

private def gpt4o_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "gpt-4o", name: "GPT-4o", provider: "azure")
end

# Captures the AAD token-request (url + form) and returns a canned response instead of
# hitting login.microsoftonline.com — keeps the AAD path fully offline. `calls` counts
# how many times the real POST seam fired so caching/refresh can be asserted.
private class StubAadAzure < CrystalLLM::Providers::Azure
  getter aad_url : String? = nil
  getter aad_form : Hash(String, String)? = nil
  getter calls : Int32 = 0
  property canned_body : String = %({"access_token": "aad-token-xyz", "token_type": "Bearer", "expires_in": 3599})

  protected def post_aad_token(url : String, form : Hash(String, String)) : Crest::Response
    @aad_url = url
    @aad_form = form
    @calls += 1
    Crest::Response.new(
      HTTP::Client::Response.new(200, body: @canned_body),
      Crest::Request.new(:post, url)
    )
  end
end

private def aad_config(base : String = "https://my-resource.openai.azure.com") : CrystalLLM::Configuration
  config = CrystalLLM::Configuration.new
  config.azure_api_base = base
  config.azure_tenant_id = "tenant-123"
  config.azure_client_id = "client-abc"
  config.azure_client_secret = "secret-shh"
  config
end

describe CrystalLLM::Providers::Azure do
  describe "Configuration reopen" do
    it "adds the azure_* keys to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("azure_api_key")
      CrystalLLM::Configuration.options.should contain("azure_api_base")
      CrystalLLM::Configuration.options.should contain("azure_ai_auth_token")
    end

    it "reads azure_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("azure_api_key").should be_false
      config.azure_api_key = "test"
      config.configured?("azure_api_key").should be_true
      config["azure_api_key"]?.should eq("test")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("azure").should eq(CrystalLLM::Providers::Azure)
    end
  end

  describe "configuration_requirements" do
    it "requires azure_api_key and azure_api_base" do
      CrystalLLM::Providers::Azure.configuration_requirements.should eq(["azure_api_key", "azure_api_base"])
    end
  end

  describe "#api_base / #headers" do
    it "uses azure_api_base and an api-key header" do
      provider = configured_azure("https://my-resource.openai.azure.com")
      provider.api_base.should eq("https://my-resource.openai.azure.com")
      provider.headers["api-key"].should eq("test")
      provider.headers.has_key?("Authorization").should be_false
    end

    it "falls back to a Bearer auth-token header when no api-key is set" do
      config = CrystalLLM::Configuration.new
      config.azure_api_base = "https://my-resource.openai.azure.com"
      config.azure_ai_auth_token = "tok"
      provider = CrystalLLM::Providers::Azure.new(config)
      provider.headers["Authorization"].should eq("Bearer tok")
      provider.headers.has_key?("api-key").should be_false
    end
  end

  describe "configured?" do
    it "is true with api_base + api_key" do
      config = CrystalLLM::Configuration.new
      config.azure_api_base = "https://r.openai.azure.com"
      config.azure_api_key = "test"
      CrystalLLM::Providers::Azure.configured?(config).should be_true
    end

    it "is true with api_base + auth_token" do
      config = CrystalLLM::Configuration.new
      config.azure_api_base = "https://r.openai.azure.com"
      config.azure_ai_auth_token = "tok"
      CrystalLLM::Providers::Azure.configured?(config).should be_true
    end

    it "is false with api_base but no auth" do
      config = CrystalLLM::Configuration.new
      config.azure_api_base = "https://r.openai.azure.com"
      CrystalLLM::Providers::Azure.configured?(config).should be_false
    end
  end

  describe "#completion_url / #models_url (azure_endpoint)" do
    it "uses the resource-base chat endpoint by default" do
      provider = configured_azure("https://r.openai.azure.com")
      provider.completion_url.should eq("models/chat/completions?api-version=2024-05-01-preview")
    end

    it "returns an empty chat path when the base already targets /chat/completions" do
      provider = configured_azure("https://r.openai.azure.com/openai/deployments/gpt-4o/chat/completions")
      provider.completion_url.should eq("")
    end

    it "uses the deployment-base chat endpoint" do
      provider = configured_azure("https://r.openai.azure.com/openai/deployments/gpt-4o")
      provider.completion_url.should eq("chat/completions?api-version=2024-05-01-preview")
    end

    it "honors an explicit api-version in the base" do
      provider = configured_azure("https://r.openai.azure.com/openai/deployments/gpt-4o?api-version=2025-01-01")
      provider.completion_url.should eq("chat/completions?api-version=2025-01-01")
    end

    it "uses the openai/v1 chat endpoint without a default version" do
      provider = configured_azure("https://r.openai.azure.com/openai/v1")
      provider.completion_url.should eq("chat/completions")
    end

    it "builds the resource-base models URL" do
      provider = configured_azure("https://r.openai.azure.com")
      provider.models_url.should eq("https://r.openai.azure.com/openai/v1/models?api-version=preview")
    end

    it "builds the openai/v1 models URL" do
      provider = configured_azure("https://r.openai.azure.com/openai/v1")
      provider.models_url.should eq("models?api-version=preview")
    end
  end

  describe "#render_payload" do
    it "produces the expected Azure chat JSON for a simple user message" do
      provider = configured_azure
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: gpt4o_model,
        stream: false
      )

      payload["model"].as_s.should eq("gpt-4o")
      payload["stream"].as_bool.should be_false
      payload["temperature"].as_f.should eq(0.7)
      payload.has_key?("tools").should be_false

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      msgs[0].as_h["content"].as_s.should eq("hi")
    end

    it "emits a system role verbatim (no developer remap)" do
      provider = configured_azure
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: "be terse")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: gpt4o_model,
        stream: false
      )
      payload["messages"].as_a[0].as_h["role"].as_s.should eq("system")
    end
  end

  describe "#parse_completion_response" do
    it "turns an Azure completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "model": "gpt-4o",
        "choices": [
          {"message": {"role": "assistant", "content": "Hello there!"}}
        ],
        "usage": {"prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17}
      }
      JSON
      provider = configured_azure
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello there!")
      message.model_id.should eq("gpt-4o")
      message.input_tokens.should eq(12)
      message.output_tokens.should eq(5)
    end
  end

  describe "#build_chunk" do
    it "turns an Azure streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "gpt-4o",
        "choices": [{"delta": {"content": "Hel"}}]
      }
      JSON
      provider = configured_azure
      chunk = provider.build_chunk(data)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("gpt-4o")
      chunk.content.should eq("Hel")
    end
  end

  describe "#parse_list_models_response" do
    it "parses an Azure models list (inherited from OpenAI)" do
      body = <<-JSON
      {"data": [{"id": "gpt-4o", "object": "model", "owned_by": "azure"}]}
      JSON
      provider = configured_azure
      models = provider.parse_list_models_response(
        build_response(200, body), "azure", CrystalLLM::Providers::Azure.capabilities
      )
      models.size.should eq(1)
      models[0].id.should eq("gpt-4o")
      models[0].provider.should eq("azure")
    end
  end

  describe ".assume_models_exist?" do
    it "is true (Azure uses deployment names)" do
      CrystalLLM::Providers::Azure.assume_models_exist?.should be_true
    end
  end

  describe "AAD client-credentials auth" do
    describe "api-key precedence (default path is unchanged)" do
      it "still emits the api-key header when azure_api_key is set, even with AAD config" do
        config = aad_config
        config.azure_api_key = "test"
        provider = StubAadAzure.new(config)

        provider.headers["api-key"].should eq("test")
        provider.headers.has_key?("Authorization").should be_false
        # the api-key path must never trigger a token POST
        provider.calls.should eq(0)
      end
    end

    describe "#aad_configured?" do
      it "is true only when all three AAD props are present" do
        StubAadAzure.new(aad_config).aad_configured?.should be_true

        partial = aad_config
        partial.azure_client_secret = nil
        # no api-key/auth-token, missing a credential -> not configured at all
        CrystalLLM::Providers::Azure.configured?(partial).should be_false
      end
    end

    describe "#aad_token_url / #aad_token_form (request shape)" do
      it "targets the tenant's v2.0 token endpoint" do
        StubAadAzure.new(aad_config).aad_token_url
          .should eq("https://login.microsoftonline.com/tenant-123/oauth2/v2.0/token")
      end

      it "builds a client-credentials grant body with the cognitive-services scope" do
        form = StubAadAzure.new(aad_config).aad_token_form
        form["grant_type"].should eq("client_credentials")
        form["client_id"].should eq("client-abc")
        form["client_secret"].should eq("secret-shh")
        form["scope"].should eq("https://cognitiveservices.azure.com/.default")
      end
    end

    describe "#headers (AAD path)" do
      it "POSTs the grant and sets a Bearer header from the access_token" do
        provider = StubAadAzure.new(aad_config)

        provider.headers["Authorization"].should eq("Bearer aad-token-xyz")
        provider.headers.has_key?("api-key").should be_false

        # the captured request must match the documented URL + form shape
        provider.aad_url.should eq("https://login.microsoftonline.com/tenant-123/oauth2/v2.0/token")
        provider.aad_form.should eq({
          "grant_type"    => "client_credentials",
          "client_id"     => "client-abc",
          "client_secret" => "secret-shh",
          "scope"         => "https://cognitiveservices.azure.com/.default",
        })
      end

      it "caches the token across calls (a single POST for repeated header reads)" do
        provider = StubAadAzure.new(aad_config)

        provider.headers
        provider.headers
        provider.aad_access_token

        provider.calls.should eq(1)
      end

      it "re-POSTs once the cached token has expired" do
        provider = StubAadAzure.new(aad_config)
        # expires_in within the 60s safety skew -> treated as already lapsed
        provider.canned_body = %({"access_token": "first", "expires_in": 10})
        provider.headers["Authorization"].should eq("Bearer first")

        provider.canned_body = %({"access_token": "second", "expires_in": 3599})
        provider.headers["Authorization"].should eq("Bearer second")
        provider.calls.should eq(2)
      end

      it "raises a clear error when the token response has no access_token" do
        provider = StubAadAzure.new(aad_config)
        provider.canned_body = %({"error": "invalid_client"})

        expect_raises(CrystalLLM::ConfigurationError, /no access_token/) do
          provider.aad_access_token
        end
      end
    end

    describe ".configured? / #ensure_configured!" do
      it "is configured with api_base + a complete AAD triple (no api-key/auth-token)" do
        CrystalLLM::Providers::Azure.configured?(aad_config).should be_true
        # constructing must not raise (ensure_configured! accepts the AAD triple)
        StubAadAzure.new(aad_config)
      end
    end
  end
end
