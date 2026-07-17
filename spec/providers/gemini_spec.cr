require "../spec_helper"
require "../../src/crystal_llm/providers/gemini"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_gemini : CrystalLLM::Providers::Gemini
  config = CrystalLLM::Configuration.new
  config.gemini_api_key = "test"
  CrystalLLM::Providers::Gemini.new(config)
end

private def flash_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", provider: "gemini")
end

describe CrystalLLM::Providers::Gemini do
  describe "Configuration reopen" do
    it "adds gemini_api_key/base to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("gemini_api_key")
      CrystalLLM::Configuration.options.should contain("gemini_api_base")
    end

    it "reads gemini_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("gemini_api_key").should be_false
      config.gemini_api_key = "test"
      config.configured?("gemini_api_key").should be_true
      config["gemini_api_key"]?.should eq("test")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("gemini").should eq(CrystalLLM::Providers::Gemini)
    end
  end

  describe "#api_base / #headers" do
    it "defaults api_base and builds the x-goog-api-key header" do
      provider = configured_gemini
      provider.api_base.should eq("https://generativelanguage.googleapis.com/v1beta")
      provider.headers["x-goog-api-key"].should eq("test")
    end

    it "honors a configured gemini_api_base" do
      config = CrystalLLM::Configuration.new
      config.gemini_api_key = "test"
      config.gemini_api_base = "https://proxy.test/v1beta"
      CrystalLLM::Providers::Gemini.new(config).api_base.should eq("https://proxy.test/v1beta")
    end
  end

  describe "#render_payload" do
    it "produces the expected Gemini contents/generationConfig JSON for a simple user message" do
      provider = configured_gemini
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: flash_model,
        stream: false
      )

      payload.has_key?("model").should be_false
      payload.has_key?("tools").should be_false

      gen = payload["generationConfig"].as_h
      gen["temperature"].as_f.should eq(0.7)

      contents = payload["contents"].as_a
      contents.size.should eq(1)
      entry = contents[0].as_h
      entry["role"].as_s.should eq("user")
      parts = entry["parts"].as_a
      parts.size.should eq(1)
      parts[0].as_h["text"].as_s.should eq("hi")
    end

    it "sets @model_id so completion_url / stream_url interpolate it" do
      provider = configured_gemini
      provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: flash_model,
        stream: false
      )
      provider.completion_url.should eq("models/gemini-2.0-flash:generateContent")
      provider.stream_url.should eq("models/gemini-2.0-flash:streamGenerateContent?alt=sse")
    end

    it "omits temperature when nil" do
      provider = configured_gemini
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: flash_model,
        stream: false
      )
      payload["generationConfig"].as_h.has_key?("temperature").should be_false
    end

    it "maps the assistant role to model" do
      provider = configured_gemini
      messages = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi"),
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "hello"),
      ]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: flash_model,
        stream: false
      )
      contents = payload["contents"].as_a
      contents[1].as_h["role"].as_s.should eq("model")
    end

    it "adds a single tools entry with functionDeclarations" do
      provider = configured_gemini
      tool = CrystalLLM::DynamicTool.new(
        "search", "Search the web",
        {"type"       => JSON::Any.new("object"),
         "properties" => JSON::Any.new({"q" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)} of String => JSON::Any),
         "required"   => JSON::Any.new([JSON::Any.new("q")])} of String => JSON::Any
      ) { |args| args["q"].as_s }

      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool},
        temperature: nil,
        model: flash_model,
        stream: false
      )

      tools = payload["tools"].as_a
      tools.size.should eq(1)
      decls = tools[0].as_h["functionDeclarations"].as_a
      decls.size.should eq(1)
      decl = decls[0].as_h
      decl["name"].as_s.should eq("search")
      decl["description"].as_s.should eq("Search the web")
      params = decl["parameters"].as_h
      params["type"].as_s.should eq("OBJECT")
      params["properties"].as_h["q"].as_h["type"].as_s.should eq("STRING")
      params["required"].as_a.map(&.as_s).should eq(["q"])
    end

    it "emits toolConfig.functionCallingConfig (any + allowedFunctionNames) from tool_prefs" do
      provider = configured_gemini
      tool = CrystalLLM::DynamicTool.new("search", "Search", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: flash_model,
        stream: false,
        # calls is ignored by Gemini (no parallel control)
        tool_prefs: {"choice" => "search", "calls" => "one"} of String => String?
      )
      fcc = payload["toolConfig"].as_h["functionCallingConfig"].as_h
      fcc["mode"].as_s.should eq("any")
      fcc["allowedFunctionNames"].as_a.map(&.as_s).should eq(["search"])
    end

    it "maps choice=auto to mode auto with no allowedFunctionNames" do
      provider = configured_gemini
      tool = CrystalLLM::DynamicTool.new("search", "Search", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: flash_model,
        stream: false,
        tool_prefs: {"choice" => "auto", "calls" => nil} of String => String?
      )
      fcc = payload["toolConfig"].as_h["functionCallingConfig"].as_h
      fcc["mode"].as_s.should eq("auto")
      fcc.has_key?("allowedFunctionNames").should be_false
    end

    it "omits toolConfig when tool_prefs is nil" do
      provider = configured_gemini
      tool = CrystalLLM::DynamicTool.new("search", "Search", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: flash_model,
        stream: false
      )
      payload.has_key?("toolConfig").should be_false
    end

    it "rewrites a schema into Gemini responseSchema (uppercased types) for a < 2.5 model" do
      provider = configured_gemini
      schema = JSON.parse(%({"name":"person","schema":{"type":"object","properties":{"name":{"type":"string"}}}}))
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: flash_model,
        stream: false,
        schema: schema
      )
      gen = payload["generationConfig"].as_h
      gen["responseMimeType"].as_s.should eq("application/json")
      gen.has_key?("responseJsonSchema").should be_false
      rs = gen["responseSchema"].as_h
      rs["type"].as_s.should eq("OBJECT")
      rs["properties"].as_h["name"].as_h["type"].as_s.should eq("STRING")
    end

    it "adds a thinkingConfig when thinking is enabled" do
      provider = configured_gemini
      thinking = CrystalLLM::Thinking::Config.new(effort: "high", budget: 1024)
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: flash_model,
        stream: false,
        thinking: thinking
      )
      tc = payload["generationConfig"].as_h["thinkingConfig"].as_h
      tc["includeThoughts"].as_bool.should be_true
      tc["thinkingLevel"].as_s.should eq("high")
      tc["thinkingBudget"].as_i.should eq(1024)
    end
  end

  describe "#parse_completion_response" do
    it "turns a Gemini completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "candidates": [
          {"content": {"parts": [{"text": "Hello there!"}], "role": "model"}}
        ],
        "modelVersion": "gemini-2.0-flash",
        "usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 5}
      }
      JSON
      provider = configured_gemini
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello there!")
      message.model_id.should eq("gemini-2.0-flash")
      message.input_tokens.should eq(12)
      message.output_tokens.should eq(5)
      message.tool_call?.should be_false
    end

    it "subtracts cached tokens from the prompt count and sums thought tokens into output" do
      body = <<-JSON
      {
        "candidates": [{"content": {"parts": [{"text": "x"}]}}],
        "usageMetadata": {
          "promptTokenCount": 20,
          "cachedContentTokenCount": 4,
          "candidatesTokenCount": 5,
          "thoughtsTokenCount": 3
        }
      }
      JSON
      provider = configured_gemini
      message = provider.parse_completion_response(build_response(200, body))
      message.input_tokens.should eq(16)
      message.output_tokens.should eq(8)
      message.cached_tokens.should eq(4)
      message.thinking_tokens.should eq(3)
    end

    it "parses function-call parts into tool calls" do
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
      provider = configured_gemini
      message = provider.parse_completion_response(build_response(200, body))

      message.tool_call?.should be_true
      calls = message.tool_calls
      raise "no tool calls" unless calls
      calls.size.should eq(1)
      call = calls.values.first
      call.name.should eq("get_weather")
      call.arguments["city"].as_s.should eq("Paris")
    end

    # Bug 12 regression: a tool-only response (functionCall, no text parts) must
    # carry content "" (not nil) to match ruby's `extract_text_parts || parse_content`.
    it "yields empty-string content (not nil) for a tool-only response" do
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
      provider = configured_gemini
      message = provider.parse_completion_response(build_response(200, body))

      message.tool_call?.should be_true
      message.content.should eq("")
      message.content.should_not be_nil
    end

    it "raises on an error body" do
      body = %({"error": {"code": 400, "message": "bad key"}})
      provider = configured_gemini
      expect_raises(CrystalLLM::Error, "bad key") do
        provider.parse_completion_response(build_response(400, body))
      end
    end

    it "attaches thinking from thought parts + thoughtSignature" do
      body = <<-JSON
      {
        "candidates": [
          {"content": {"parts": [
            {"thought": true, "text": "Reasoning ", "thoughtSignature": "g-sig"},
            {"thought": true, "text": "more."},
            {"text": "Final answer."}
          ]}}
        ],
        "modelVersion": "gemini-2.5-flash",
        "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 5, "thoughtsTokenCount": 7}
      }
      JSON
      provider = configured_gemini
      message = provider.parse_completion_response(build_response(200, body))

      message.content.should eq("Final answer.")
      thinking = message.thinking.should_not be_nil
      thinking.text.should eq("Reasoning more.")
      thinking.signature.should eq("g-sig")
    end
  end

  describe "#build_chunk" do
    it "turns a Gemini streaming event into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "candidates": [{"content": {"parts": [{"text": "Hel"}]}}],
        "modelVersion": "gemini-2.0-flash"
      }
      JSON
      provider = configured_gemini
      chunk = provider.build_chunk(data)
      chunk.should be_a(CrystalLLM::Chunk)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("gemini-2.0-flash")
      chunk.content.should eq("Hel")
    end

    it "carries usage tokens on the final chunk and nil output for an empty delta" do
      data = JSON.parse(<<-JSON)
      {
        "candidates": [{"content": {"parts": [{"text": ""}]}}],
        "usageMetadata": {"promptTokenCount": 3, "candidatesTokenCount": 4}
      }
      JSON
      provider = configured_gemini
      chunk = provider.build_chunk(data)
      chunk.input_tokens.should eq(3)
      chunk.output_tokens.should eq(4)
    end
  end

  describe "#format_messages (tool grouping)" do
    # ruby_llm 1.16.0 / 854342e3 (Fixes #678): Gemini's generateContent spec only
    # accepts "user"/"model" content roles; the historical `role: "function"` for
    # collapsed tool results was never valid Gemini API shape.
    it "collapses consecutive tool results into one user-role content entry" do
      provider = configured_gemini
      calls = {
        "call_1" => CrystalLLM::ToolCall.new(id: "call_1", name: "get_weather"),
        "call_2" => CrystalLLM::ToolCall.new(id: "call_2", name: "get_time"),
      }
      messages = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi"),
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, tool_calls: calls),
        CrystalLLM::Message.new(role: CrystalLLM::Role::Tool, content: "sunny", tool_call_id: "call_1"),
        CrystalLLM::Message.new(role: CrystalLLM::Role::Tool, content: "noon", tool_call_id: "call_2"),
      ]
      contents = provider.format_messages(messages)
      contents.size.should eq(3)

      tool_response_entry = contents[2].as_h
      tool_response_entry["role"].as_s.should eq("user")
      parts = tool_response_entry["parts"].as_a
      parts.size.should eq(2)
      parts[0].as_h["functionResponse"].as_h["name"].as_s.should eq("get_weather")
      parts[1].as_h["functionResponse"].as_h["name"].as_s.should eq("get_time")
    end
  end

  describe "Capabilities" do
    it "classifies model families, windows, and capabilities" do
      caps = CrystalLLM::Providers::Gemini::Capabilities
      caps.context_window_for("gemini-2.0-flash").should eq(1_048_576)
      caps.max_tokens_for("gemini-2.0-flash").should eq(8_192)
      caps.pricing_family("gemini-2.0-flash").should eq("flash_2")
      caps.critical_capabilities_for("gemini-2.0-flash").should contain("function_calling")
      caps.critical_capabilities_for("gemini-2.0-flash").should contain("vision")
    end

    it "builds wire pricing consumable by Model::Pricing" do
      caps = CrystalLLM::Providers::Gemini::Capabilities
      pricing = CrystalLLM::Model::Pricing.new(caps.pricing_for("gemini-2.0-flash"))
      pricing.text_tokens.input.should eq(0.10)
      pricing.text_tokens.output.should eq(0.40)
    end
  end

  describe "#parse_list_models_response" do
    it "strips the models/ prefix and builds Model::Info" do
      body = <<-JSON
      {
        "models": [
          {"name": "models/gemini-2.0-flash", "displayName": "Gemini 2.0 Flash",
           "inputTokenLimit": 1048576, "outputTokenLimit": 8192,
           "version": "2.0", "supportedGenerationMethods": ["generateContent"]}
        ]
      }
      JSON
      provider = configured_gemini
      models = provider.parse_list_models_response(
        build_response(200, body), "gemini", CrystalLLM::Providers::Gemini::Capabilities
      )
      models.size.should eq(1)
      models[0].id.should eq("gemini-2.0-flash")
      models[0].name.should eq("Gemini 2.0 Flash")
      models[0].context_window.should eq(1_048_576)
      models[0].max_output_tokens.should eq(8_192)
    end
  end

  describe "#format_tool_call (thoughtSignature fallback)" do
    it "borrows the message thinking signature for the first call lacking one" do
      provider = configured_gemini
      tool_calls = {
        "a" => CrystalLLM::ToolCall.new(id: "a", name: "first", arguments: {} of String => JSON::Any),
        "b" => CrystalLLM::ToolCall.new(id: "b", name: "second", arguments: {} of String => JSON::Any,
          thought_signature: "own-sig"),
      }
      msg = CrystalLLM::Message.new(
        role: CrystalLLM::Role::Assistant,
        tool_calls: tool_calls,
        thinking: CrystalLLM::Thinking.new(text: "reasoning", signature: "fallback-sig")
      )

      parts = provider.format_tool_call(msg)
      sig_a = parts[0].as_h["thoughtSignature"]?.try(&.as_s)
      sig_b = parts[1].as_h["thoughtSignature"]?.try(&.as_s)

      # First call has no own signature -> borrows the message fallback (once).
      sig_a.should eq("fallback-sig")
      # Second call keeps its own; the fallback was already used.
      sig_b.should eq("own-sig")
    end

    it "omits thoughtSignature when there is neither an own nor a fallback signature" do
      provider = configured_gemini
      tool_calls = {
        "a" => CrystalLLM::ToolCall.new(id: "a", name: "first", arguments: {} of String => JSON::Any),
      }
      msg = CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, tool_calls: tool_calls)

      parts = provider.format_tool_call(msg)
      parts[0].as_h.has_key?("thoughtSignature").should be_false
    end
  end
end
