require "../spec_helper"
require "../../src/crystal_llm/providers/vertexai"
require "openssl_ext"
require "base64"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

# A throwaway RSA key + service-account JSON, generated once per run (NO real GCP key).
private RSA_KEY = OpenSSL::PKey::RSA.new(2048)

private def sa_private_pem : String
  RSA_KEY.to_pem
end

private def sa_public_pem : String
  RSA_KEY.public_key.to_pem
end

private def service_account_json(token_uri : String = "https://oauth2.googleapis.com/token") : String
  {
    "type"         => "service_account",
    "client_email" => "svc@my-project.iam.gserviceaccount.com",
    "private_key"  => sa_private_pem,
    "token_uri"    => token_uri,
  }.to_json
end

# A VertexAI subclass that stubs the network token exchange: it records the form body it
# was asked to POST and returns a canned token response (NO live GCP call).
private class StubVertexAI < CrystalLLM::Providers::VertexAI
  getter requested_token_uri : String?
  getter requested_form_body : String?
  property canned_response : String = %({"access_token":"ya29.minted-token","expires_in":3600,"token_type":"Bearer"})
  getter request_token_calls : Int32 = 0

  protected def request_token(token_uri : String, form_body : String) : String
    @requested_token_uri = token_uri
    @requested_form_body = form_body
    @request_token_calls += 1
    @canned_response
  end
end

private def stub_vertexai(key : String = service_account_json) : StubVertexAI
  config = CrystalLLM::Configuration.new
  config.vertexai_project_id = "my-project"
  config.vertexai_location = "us-central1"
  config.vertexai_service_account_key = key
  StubVertexAI.new(config)
end

private def configured_vertexai : CrystalLLM::Providers::VertexAI
  config = CrystalLLM::Configuration.new
  config.vertexai_project_id = "my-project"
  config.vertexai_location = "us-central1"
  config.vertexai_service_account_key = "test"
  CrystalLLM::Providers::VertexAI.new(config)
end

private def gemini_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", provider: "vertexai")
end

describe CrystalLLM::Providers::VertexAI do
  describe "Configuration reopen" do
    it "adds vertexai options to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("vertexai_project_id")
      CrystalLLM::Configuration.options.should contain("vertexai_location")
      CrystalLLM::Configuration.options.should contain("vertexai_service_account_key")
    end

    it "reads vertexai_project_id via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("vertexai_project_id").should be_false
      config.vertexai_project_id = "p"
      config.configured?("vertexai_project_id").should be_true
      config["vertexai_project_id"]?.should eq("p")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("vertexai").should eq(CrystalLLM::Providers::VertexAI)
    end
  end

  describe "configuration_requirements" do
    it "requires project id and location" do
      CrystalLLM::Providers::VertexAI.configuration_requirements.should eq(["vertexai_project_id", "vertexai_location"])
    end

    it "raises when required config is missing" do
      config = CrystalLLM::Configuration.new
      expect_raises(CrystalLLM::ConfigurationError) do
        CrystalLLM::Providers::VertexAI.new(config)
      end
    end
  end

  describe "#api_base / #headers" do
    it "builds a regional api_base" do
      configured_vertexai.api_base.should eq("https://us-central1-aiplatform.googleapis.com/v1beta1")
    end

    it "uses the global endpoint when location is global" do
      config = CrystalLLM::Configuration.new
      config.vertexai_project_id = "p"
      config.vertexai_location = "global"
      CrystalLLM::Providers::VertexAI.new(config).api_base.should eq("https://aiplatform.googleapis.com/v1beta1")
    end

    it "raises a clear ConfigurationError when the service-account key is not valid JSON" do
      # `configured_vertexai` sets the key to the non-JSON string "test"; `headers`
      # now mints a real OAuth bearer, so it must reject the bad key rather than emit it.
      expect_raises(CrystalLLM::ConfigurationError, /not valid JSON/) do
        configured_vertexai.headers
      end
    end
  end

  describe "#completion_url / #stream_url" do
    it "builds the generateContent path after a render captures the model" do
      provider = configured_vertexai
      provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: gemini_model
      )
      provider.completion_url.should eq(
        "projects/my-project/locations/us-central1/publishers/google/models/gemini-2.0-flash:generateContent"
      )
      provider.stream_url.should eq(
        "projects/my-project/locations/us-central1/publishers/google/models/gemini-2.0-flash:streamGenerateContent?alt=sse"
      )
    end
  end

  describe "#render_payload" do
    it "produces the expected Gemini contents JSON for a simple user message" do
      provider = configured_vertexai
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: gemini_model,
        stream: false
      )

      payload.has_key?("model").should be_false
      payload["generationConfig"].as_h["temperature"].as_f.should eq(0.7)
      payload.has_key?("tools").should be_false

      contents = payload["contents"].as_a
      contents.size.should eq(1)
      entry = contents[0].as_h
      entry["role"].as_s.should eq("user")
      parts = entry["parts"].as_a
      parts.size.should eq(1)
      parts[0].as_h["text"].as_s.should eq("hi")
    end

    it "omits temperature when nil and maps assistant role to model" do
      provider = configured_vertexai
      messages = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi"),
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "hello"),
      ]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: gemini_model
      )
      payload["generationConfig"].as_h.has_key?("temperature").should be_false

      contents = payload["contents"].as_a
      contents[1].as_h["role"].as_s.should eq("model")
    end

    it "adds responseMimeType when a schema envelope is present (schema conversion deferred)" do
      provider = configured_vertexai
      schema = JSON.parse(%({"name":"person","schema":{"type":"object"},"strict":true}))
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: gemini_model,
        schema: schema
      )
      payload["generationConfig"].as_h["responseMimeType"].as_s.should eq("application/json")
    end

    it "serializes tools into functionDeclarations" do
      provider = configured_vertexai
      tool = CrystalLLM::DynamicTool.new(
        "search", "Search the web",
        {"type"       => JSON::Any.new("object"),
         "properties" => JSON::Any.new({"q" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)} of String => JSON::Any),
         "required"   => JSON::Any.new([JSON::Any.new("q")])} of String => JSON::Any
      ) { |args| args["q"].as_s }

      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool} of String => CrystalLLM::Tool,
        temperature: nil,
        model: gemini_model
      )

      tools_arr = payload["tools"].as_a
      tools_arr.size.should eq(1)
      decls = tools_arr[0].as_h["functionDeclarations"].as_a
      decls.size.should eq(1)
      decl = decls[0].as_h
      decl["name"].as_s.should eq("search")
      decl["description"].as_s.should eq("Search the web")
      params = decl["parameters"].as_h
      params["type"].as_s.should eq("OBJECT")
      params["properties"].as_h["q"].as_h["type"].as_s.should eq("STRING")
      params["required"].as_a.map(&.as_s).should eq(["q"])
    end

    # Bug 9 regression: VertexAI previously omitted Gemini's anyOf (nullable)
    # normalization, so an `anyOf: [{type:string}, {type:null}]` property emitted a
    # bare STRING with no nullable flag (and could even mis-type). It must now
    # collapse to the non-null branch's type with `nullable: true`.
    it "normalizes anyOf (nullable) properties like Gemini" do
      provider = configured_vertexai
      tool = CrystalLLM::DynamicTool.new(
        "lookup", "Look something up",
        {"type"       => JSON::Any.new("object"),
         "properties" => JSON::Any.new({
           "name" => JSON::Any.new({
             "description" => JSON::Any.new("optional name"),
             "anyOf"       => JSON::Any.new([
               JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
               JSON::Any.new({"type" => JSON::Any.new("null")} of String => JSON::Any),
             ]),
           } of String => JSON::Any),
         } of String => JSON::Any),
         "required" => JSON::Any.new([] of JSON::Any)} of String => JSON::Any
      ) { |args| args["name"]?.try(&.as_s?) || "" }

      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"lookup" => tool} of String => CrystalLLM::Tool,
        temperature: nil,
        model: gemini_model
      )

      decl = payload["tools"].as_a[0].as_h["functionDeclarations"].as_a[0].as_h
      name_prop = decl["parameters"].as_h["properties"].as_h["name"].as_h
      name_prop["type"].as_s.should eq("STRING")
      name_prop["nullable"].as_bool.should be_true
      name_prop["description"].as_s.should eq("optional name")
    end
  end

  describe "#format_messages" do
    it "collapses consecutive tool results into a single function entry" do
      provider = configured_vertexai
      calls = {"call_1" => CrystalLLM::ToolCall.new(id: "call_1", name: "get_weather")}
      messages = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "weather?"),
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, tool_calls: calls),
        CrystalLLM::Message.new(role: CrystalLLM::Role::Tool, content: "sunny", tool_call_id: "call_1"),
      ]
      formatted = provider.format_messages(messages)
      formatted.size.should eq(3)

      # assistant tool_call -> functionCall part
      assistant = formatted[1].as_h
      assistant["role"].as_s.should eq("model")
      fc = assistant["parts"].as_a[0].as_h["functionCall"].as_h
      fc["name"].as_s.should eq("get_weather")

      # tool result -> function role with functionResponse, named from the remembered call
      tool_entry = formatted[2].as_h
      tool_entry["role"].as_s.should eq("function")
      fr = tool_entry["parts"].as_a[0].as_h["functionResponse"].as_h
      fr["name"].as_s.should eq("get_weather")
    end
  end

  describe "#parse_completion_response" do
    it "turns a Gemini completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "candidates": [
          {"content": {"parts": [{"text": "Hello there!"}], "role": "model"}}
        ],
        "usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 5},
        "modelVersion": "gemini-2.0-flash"
      }
      JSON
      provider = configured_vertexai
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello there!")
      message.model_id.should eq("gemini-2.0-flash")
      message.input_tokens.should eq(12)
      message.output_tokens.should eq(5)
      message.tool_call?.should be_false
    end

    it "subtracts cached tokens from the prompt count for input_tokens" do
      body = <<-JSON
      {
        "candidates": [{"content": {"parts": [{"text": "ok"}]}}],
        "usageMetadata": {"promptTokenCount": 20, "cachedContentTokenCount": 8, "candidatesTokenCount": 3}
      }
      JSON
      provider = configured_vertexai
      message = provider.parse_completion_response(build_response(200, body))
      message.input_tokens.should eq(12)
      message.cached_tokens.should eq(8)
    end

    it "parses functionCall parts into tool calls" do
      body = <<-JSON
      {
        "candidates": [
          {"content": {"parts": [
            {"functionCall": {"name": "get_weather", "args": {"city": "Paris"}}}
          ]}}
        ],
        "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 8}
      }
      JSON
      provider = configured_vertexai
      message = provider.parse_completion_response(build_response(200, body))

      message.tool_call?.should be_true
      calls = message.tool_calls
      raise "no tool calls" unless calls
      calls.size.should eq(1)
      call = calls.first_value
      call.name.should eq("get_weather")
      call.arguments["city"].as_s.should eq("Paris")
    end

    it "raises on an error body" do
      body = %({"error": {"code": 401, "message": "bad creds", "status": "UNAUTHENTICATED"}})
      provider = configured_vertexai
      expect_raises(CrystalLLM::Error, "bad creds") do
        provider.parse_completion_response(build_response(401, body))
      end
    end
  end

  describe "#build_chunk" do
    it "turns a Gemini streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "candidates": [{"content": {"parts": [{"text": "Hel"}]}}],
        "modelVersion": "gemini-2.0-flash"
      }
      JSON
      provider = configured_vertexai
      chunk = provider.build_chunk(data)
      chunk.should be_a(CrystalLLM::Chunk)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("gemini-2.0-flash")
      chunk.content.should eq("Hel")
    end

    it "carries usage tokens" do
      data = JSON.parse(<<-JSON)
      {
        "candidates": [{"content": {"parts": []}}],
        "usageMetadata": {"promptTokenCount": 3, "candidatesTokenCount": 4}
      }
      JSON
      provider = configured_vertexai
      chunk = provider.build_chunk(data)
      chunk.input_tokens.should eq(3)
      chunk.output_tokens.should eq(4)
    end
  end

  describe "#parse_list_models_response" do
    it "includes known models and parses API publisherModels" do
      body = <<-JSON
      {
        "publisherModels": [
          {"name": "publishers/google/models/gemini-1.5-pro", "launchStage": "GA"},
          {"name": "publishers/google/models/gemini-old", "launchStage": "DEPRECATED"}
        ]
      }
      JSON
      provider = configured_vertexai
      models = provider.parse_list_models_response(build_response(200, body), "vertexai", CrystalLLM::Providers::VertexAI.capabilities)

      ids = models.map(&.id)
      ids.should contain("gemini-2.5-flash") # from KNOWN_GOOGLE_MODELS
      ids.should contain("gemini-1.5-pro")   # from the API rows
      ids.should_not contain("gemini-old")   # DEPRECATED skipped
    end
  end

  describe "Capabilities" do
    it "classifies context window, pricing, and capabilities" do
      caps = CrystalLLM::Providers::VertexAI::Capabilities
      caps.context_window_for("gemini-2.0-flash").should eq(1_048_576)
      caps.critical_capabilities_for("gemini-2.0-flash").should contain("function_calling")
      pricing = CrystalLLM::Model::Pricing.new(caps.pricing_for("gemini-2.0-flash"))
      pricing.text_tokens.input.should eq(0.10)
      pricing.text_tokens.output.should eq(0.40)
    end
  end

  describe "service-account OAuth auth" do
    describe "#service_account" do
      it "parses the configured JSON key" do
        sa = stub_vertexai.service_account
        sa.client_email.should eq("svc@my-project.iam.gserviceaccount.com")
        sa.private_key.should eq(sa_private_pem)
        sa.token_uri.should eq("https://oauth2.googleapis.com/token")
      end

      it "accepts a filesystem path to the JSON key (convenience divergence)" do
        path = File.tempname("vertexai-sa", ".json")
        File.write(path, service_account_json)
        begin
          stub_vertexai(key: path).service_account.client_email
            .should eq("svc@my-project.iam.gserviceaccount.com")
        ensure
          File.delete(path)
        end
      end

      it "raises a ConfigurationError when the key is missing" do
        config = CrystalLLM::Configuration.new
        config.vertexai_project_id = "my-project"
        config.vertexai_location = "us-central1"
        provider = CrystalLLM::Providers::VertexAI.new(config)
        expect_raises(CrystalLLM::ConfigurationError, /not set/) do
          provider.access_token
        end
      end

      it "raises when required service-account fields are absent" do
        bad = {"type" => "service_account"}.to_json
        expect_raises(CrystalLLM::ConfigurationError, /missing required fields/) do
          stub_vertexai(key: bad).service_account
        end
      end
    end

    describe "#build_jwt_assertion" do
      it "builds an RS256 JWT with the right header + claims that verifies against the public key" do
        now = Time.utc(2026, 6, 4, 12, 0, 0)
        provider = stub_vertexai
        sa = provider.service_account
        assertion = provider.build_jwt_assertion(sa, now: now)

        # Header: RS256 + typ JWT.
        header_b64 = assertion.split('.').first
        header = JSON.parse(Base64.decode_string(header_b64))
        header["alg"].as_s.should eq("RS256")
        header["typ"].as_s.should eq("JWT")

        # Verifies (RS256) against the public key and decodes back to the claims.
        # validate: false — `now` is a fixed past instant, so we assert claims, not freshness.
        payload, _ = JWT.decode(assertion, sa_public_pem, JWT::Algorithm::RS256, validate: false)
        payload["iss"].as_s.should eq("svc@my-project.iam.gserviceaccount.com")
        payload["aud"].as_s.should eq("https://oauth2.googleapis.com/token")
        payload["scope"].as_s.should eq(
          "https://www.googleapis.com/auth/cloud-platform " \
          "https://www.googleapis.com/auth/generative-language.retriever"
        )
        payload["iat"].as_i64.should eq(now.to_unix)
        payload["exp"].as_i64.should eq((now + 1.hour).to_unix)
      end

      it "rejects tampering (signature verification fails for a different key)" do
        provider = stub_vertexai
        assertion = provider.build_jwt_assertion(now: Time.utc)
        other_pub = OpenSSL::PKey::RSA.new(2048).public_key.to_pem
        expect_raises(JWT::VerificationError) do
          JWT.decode(assertion, other_pub, JWT::Algorithm::RS256)
        end
      end
    end

    describe "#access_token (token exchange)" do
      it "POSTs the jwt-bearer grant + assertion to the token endpoint and returns the minted token" do
        provider = stub_vertexai
        token = provider.access_token
        token.should eq("ya29.minted-token")

        provider.requested_token_uri.should eq("https://oauth2.googleapis.com/token")

        # The POST body is form-encoded: grant_type=<jwt-bearer>&assertion=<jwt>.
        body = provider.requested_form_body
        raise "no form body" unless body
        params = URI::Params.parse(body)
        params["grant_type"].should eq("urn:ietf:params:oauth:grant-type:jwt-bearer")

        # The assertion is the signed JWT and verifies against the public key.
        assertion = params["assertion"]
        payload, _ = JWT.decode(assertion, sa_public_pem, JWT::Algorithm::RS256)
        payload["iss"].as_s.should eq("svc@my-project.iam.gserviceaccount.com")
      end

      it "caches the token (no second exchange while valid)" do
        provider = stub_vertexai
        provider.access_token.should eq("ya29.minted-token")
        provider.access_token.should eq("ya29.minted-token")
        provider.request_token_calls.should eq(1)
      end

      it "raises UnauthorizedError when the response has no access_token" do
        provider = stub_vertexai
        provider.canned_response = %({"error":"invalid_grant"})
        expect_raises(CrystalLLM::UnauthorizedError, /no access_token/) do
          provider.access_token
        end
      end

      it "emits the minted bearer in #headers" do
        provider = stub_vertexai
        provider.headers["Authorization"].should eq("Bearer ya29.minted-token")
      end
    end
  end
end
