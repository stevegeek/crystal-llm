require "../spec_helper"
require "../../src/crystal_llm/provider_completion"
require "../../src/crystal_llm/providers/openai"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_openai : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "sk-test"
  CrystalLLM::Providers::OpenAI.new(config)
end

private def gpt4o_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "gpt-4o", name: "GPT-4o", provider: "openai")
end

describe CrystalLLM::Providers::OpenAI do
  describe "Configuration reopen" do
    it "adds openai_api_key to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("openai_api_key")
      CrystalLLM::Configuration.options.should contain("openai_api_base")
      CrystalLLM::Configuration.options.should contain("openai_organization_id")
      CrystalLLM::Configuration.options.should contain("openai_project_id")
    end

    it "reads openai_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("openai_api_key").should be_false
      config.openai_api_key = "sk-x"
      config.configured?("openai_api_key").should be_true
      config["openai_api_key"]?.should eq("sk-x")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("openai").should eq(CrystalLLM::Providers::OpenAI)
    end
  end

  describe "#api_base / #headers" do
    it "defaults api_base and builds Authorization header" do
      provider = configured_openai
      provider.api_base.should eq("https://api.openai.com/v1")
      provider.headers["Authorization"].should eq("Bearer sk-test")
    end

    it "honors a configured openai_api_base" do
      config = CrystalLLM::Configuration.new
      config.openai_api_key = "sk-test"
      config.openai_api_base = "https://proxy.test/v1"
      CrystalLLM::Providers::OpenAI.new(config).api_base.should eq("https://proxy.test/v1")
    end
  end

  describe "#render_payload" do
    it "produces the expected OpenAI chat JSON for a simple user message" do
      provider = configured_openai
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
      payload.has_key?("stream_options").should be_false

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      msgs[0].as_h["content"].as_s.should eq("hi")
    end

    it "omits temperature when nil and adds stream_options when streaming" do
      provider = configured_openai
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: gpt4o_model,
        stream: true
      )
      payload.has_key?("temperature").should be_false
      payload["stream"].as_bool.should be_true
      payload["stream_options"].as_h["include_usage"].as_bool.should be_true
    end

    it "adds a response_format from a schema envelope" do
      provider = configured_openai
      schema = JSON.parse(%({"name":"person","schema":{"type":"object"},"strict":true}))
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: gpt4o_model,
        stream: false,
        schema: schema
      )
      rf = payload["response_format"].as_h
      rf["type"].as_s.should eq("json_schema")
      rf["json_schema"].as_h["name"].as_s.should eq("person")
    end

    it "emits a named-function tool_choice and parallel flag from tool_prefs" do
      provider = configured_openai
      tool = CrystalLLM::DynamicTool.new("search", "Search", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: gpt4o_model,
        stream: false,
        tool_prefs: {"choice" => "search", "calls" => "one"} of String => String?
      )
      tc = payload["tool_choice"].as_h
      tc["type"].as_s.should eq("function")
      tc["function"].as_h["name"].as_s.should eq("search")
      payload["parallel_tool_calls"].as_bool.should be_false
    end

    it "emits a string tool_choice for required and parallel=true for many" do
      provider = configured_openai
      tool = CrystalLLM::DynamicTool.new("search", "Search", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: gpt4o_model,
        stream: false,
        tool_prefs: {"choice" => "required", "calls" => "many"} of String => String?
      )
      payload["tool_choice"].as_s.should eq("required")
      payload["parallel_tool_calls"].as_bool.should be_true
    end

    it "omits tool_choice/parallel when tool_prefs is nil" do
      provider = configured_openai
      tool = CrystalLLM::DynamicTool.new("search", "Search", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: gpt4o_model,
        stream: false
      )
      payload.has_key?("tool_choice").should be_false
      payload.has_key?("parallel_tool_calls").should be_false
    end
  end

  describe "#parse_completion_response" do
    it "turns an OpenAI completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "model": "gpt-4o",
        "choices": [
          {"message": {"role": "assistant", "content": "Hello there!"}}
        ],
        "usage": {"prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17}
      }
      JSON
      provider = configured_openai
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello there!")
      message.model_id.should eq("gpt-4o")
      message.input_tokens.should eq(12)
      message.output_tokens.should eq(5)
      message.tool_call?.should be_false
    end

    it "parses tool calls from the message" do
      body = <<-JSON
      {
        "model": "gpt-4o",
        "choices": [
          {"message": {"role": "assistant", "content": null,
            "tool_calls": [
              {"id": "call_1", "type": "function",
               "function": {"name": "get_weather", "arguments": "{\\"city\\":\\"Paris\\"}"}}
            ]}}
        ],
        "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18}
      }
      JSON
      provider = configured_openai
      message = provider.parse_completion_response(build_response(200, body))

      message.tool_call?.should be_true
      calls = message.tool_calls
      calls.should_not be_nil
      raise "no tool calls" unless calls
      calls.size.should eq(1)
      call = calls["call_1"]
      call.name.should eq("get_weather")
      call.arguments["city"].as_s.should eq("Paris")
    end

    it "raises on an error body" do
      body = %({"error": {"message": "bad key", "type": "invalid_request_error"}})
      provider = configured_openai
      expect_raises(CrystalLLM::Error, "bad key") do
        provider.parse_completion_response(build_response(401, body))
      end
    end
  end

  describe "#build_chunk" do
    it "turns an OpenAI streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "gpt-4o",
        "choices": [{"delta": {"content": "Hel"}}]
      }
      JSON
      provider = configured_openai
      chunk = provider.build_chunk(data)
      chunk.should be_a(CrystalLLM::Chunk)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("gpt-4o")
      chunk.content.should eq("Hel")
    end

    it "carries usage tokens on the final chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "gpt-4o",
        "choices": [{"delta": {}}],
        "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7}
      }
      JSON
      provider = configured_openai
      chunk = provider.build_chunk(data)
      chunk.input_tokens.should eq(3)
      chunk.output_tokens.should eq(4)
    end
  end

  describe "#tool_for / #format_tool_calls" do
    it "serializes a tool into the OpenAI function shape" do
      tool = CrystalLLM::DynamicTool.new(
        "search", "Search the web",
        {"type"       => JSON::Any.new("object"),
         "properties" => JSON::Any.new({"q" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)} of String => JSON::Any)} of String => JSON::Any
      ) { |args| args["q"].as_s }

      provider = configured_openai
      defn = provider.tool_for(tool).as_h
      defn["type"].as_s.should eq("function")
      fn = defn["function"].as_h
      fn["name"].as_s.should eq("search")
      fn["description"].as_s.should eq("Search the web")
      fn["parameters"].as_h["type"].as_s.should eq("object")
    end
  end

  describe "Capabilities" do
    it "classifies model families and capabilities" do
      caps = CrystalLLM::Providers::OpenAI::Capabilities
      caps.model_family("gpt-4o").should eq("gpt4o")
      caps.context_window_for("gpt-4o").should eq(128_000)
      caps.critical_capabilities_for("gpt-4o").should contain("function_calling")
      caps.critical_capabilities_for("gpt-4o").should contain("vision")
    end

    it "builds wire pricing consumable by Model::Pricing" do
      caps = CrystalLLM::Providers::OpenAI::Capabilities
      pricing = CrystalLLM::Model::Pricing.new(caps.pricing_for("gpt-4o"))
      pricing.text_tokens.input.should eq(2.5)
      pricing.text_tokens.output.should eq(10.0)
    end

    # Bug 5 regression: previously-missing non-image families fell through to the
    # 0.5/1.5 fallback. They now resolve to ruby's real per-family prices.
    it "prices previously-missing non-image families from the ported table" do
      caps = CrystalLLM::Providers::OpenAI::Capabilities

      # input/output family that was absent before the fix (ruby: 5.0 / 20.0).
      caps.model_family("gpt-4o-realtime-preview").should eq("gpt4o_realtime")
      caps.input_price_for("gpt-4o-realtime-preview").should eq(5.0)
      caps.output_price_for("gpt-4o-realtime-preview").should eq(20.0)

      # price-only family: input == output == price (ruby's `{ price: 0.13 }`),
      # not the 0.5/1.5 fallback.
      caps.model_family("text-embedding-3-large").should eq("embedding3_large")
      caps.input_price_for("text-embedding-3-large").should eq(0.13)
      caps.output_price_for("text-embedding-3-large").should eq(0.13)

      # unknown family still uses the generic fallback.
      caps.input_price_for("some-unknown-model").should eq(0.5)
      caps.output_price_for("some-unknown-model").should eq(1.5)
    end
  end

  describe "Temperature.normalize" do
    it "forces 1.0 for gpt-5 / o-series and passes others through" do
      CrystalLLM::Providers::OpenAI::Temperature.normalize(0.2, "gpt-5").should eq(1.0)
      CrystalLLM::Providers::OpenAI::Temperature.normalize(0.2, "gpt-4o").should eq(0.2)
      CrystalLLM::Providers::OpenAI::Temperature.normalize(0.2, "gpt-4o-search").should be_nil
    end
  end
end
