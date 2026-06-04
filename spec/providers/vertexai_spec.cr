require "../spec_helper"
require "../../src/crystal_llm/providers/vertexai"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
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

    it "emits a best-effort Authorization header (auth deferred)" do
      configured_vertexai.headers["Authorization"].should eq("Bearer test")
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
end
