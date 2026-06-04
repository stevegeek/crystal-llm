require "../spec_helper"
require "../../src/crystal_llm/provider_completion"
require "../../src/crystal_llm/providers/mistral"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

private def configured_mistral : CrystalLLM::Providers::Mistral
  config = CrystalLLM::Configuration.new
  config.mistral_api_key = "test"
  CrystalLLM::Providers::Mistral.new(config)
end

private def mistral_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "mistral-large-latest", name: "Mistral Large", provider: "mistral")
end

describe CrystalLLM::Providers::Mistral do
  describe "Configuration reopen" do
    it "adds mistral_api_key to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("mistral_api_key")
    end

    it "reads mistral_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("mistral_api_key").should be_false
      config.mistral_api_key = "test"
      config.configured?("mistral_api_key").should be_true
      config["mistral_api_key"]?.should eq("test")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("mistral").should eq(CrystalLLM::Providers::Mistral)
    end
  end

  describe "configuration class methods" do
    it "requires and exposes mistral_api_key" do
      CrystalLLM::Providers::Mistral.configuration_requirements.should eq(["mistral_api_key"])
      CrystalLLM::Providers::Mistral.configuration_options.should eq(["mistral_api_key"])
    end

    it "uses the Mistral capabilities helper" do
      CrystalLLM::Providers::Mistral.capabilities.should eq(CrystalLLM::Providers::Mistral::Capabilities)
    end
  end

  describe "#api_base / #headers" do
    it "uses the Mistral api_base and Bearer header" do
      provider = configured_mistral
      provider.api_base.should eq("https://api.mistral.ai/v1")
      provider.headers["Authorization"].should eq("Bearer test")
    end
  end

  describe "endpoint urls (inherited from OpenAI)" do
    it "uses chat/completions and models" do
      provider = configured_mistral
      provider.completion_url.should eq("chat/completions")
      provider.stream_url.should eq("chat/completions")
      provider.models_url.should eq("models")
    end
  end

  describe "#render_payload" do
    it "produces the expected Mistral chat JSON for a simple user message" do
      provider = configured_mistral
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: mistral_model,
        stream: false
      )

      payload["model"].as_s.should eq("mistral-large-latest")
      payload["stream"].as_bool.should be_false
      payload["temperature"].as_f.should eq(0.7)
      payload.has_key?("tools").should be_false

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      msgs[0].as_h["content"].as_s.should eq("hi")
    end

    it "drops OpenAI's stream_options even when streaming" do
      provider = configured_mistral
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: mistral_model,
        stream: true
      )
      payload["stream"].as_bool.should be_true
      payload.has_key?("stream_options").should be_false
      payload.has_key?("temperature").should be_false
    end

    it "shapes reasoning_effort for an adjustable-reasoning model" do
      provider = configured_mistral
      model = CrystalLLM::Model::Info.build(id: "mistral-small-latest", provider: "mistral")
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: model,
        stream: false,
        thinking: CrystalLLM::Thinking::Config.new(effort: "high")
      )
      payload["reasoning_effort"].as_s.should eq("high")
    end

    it "uses prompt_mode reasoning for a native magistral model" do
      provider = configured_mistral
      model = CrystalLLM::Model::Info.build(id: "magistral-medium-latest", provider: "mistral")
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: model,
        stream: false,
        thinking: CrystalLLM::Thinking::Config.new(effort: "high")
      )
      payload["prompt_mode"].as_s.should eq("reasoning")
      payload.has_key?("reasoning_effort").should be_false
    end
  end

  describe "#normalize_required_tool_choice" do
    it "rewrites an 'any' tool_choice into a named-function object for a single tool" do
      provider = configured_mistral
      payload = {
        "tool_choice" => JSON::Any.new("any"),
        "tools"       => JSON::Any.new([
          JSON::Any.new({
            "type"     => JSON::Any.new("function"),
            "function" => JSON::Any.new({"name" => JSON::Any.new("get_weather")} of String => JSON::Any),
          } of String => JSON::Any),
        ]),
      } of String => JSON::Any
      provider.normalize_required_tool_choice(payload)

      tc = payload["tool_choice"].as_h
      tc["type"].as_s.should eq("function")
      tc["function"].as_h["name"].as_s.should eq("get_weather")
    end

    it "leaves 'any' alone when more than one tool is present" do
      provider = configured_mistral
      tool_entry = JSON::Any.new({
        "type"     => JSON::Any.new("function"),
        "function" => JSON::Any.new({"name" => JSON::Any.new("a")} of String => JSON::Any),
      } of String => JSON::Any)
      payload = {
        "tool_choice" => JSON::Any.new("any"),
        "tools"       => JSON::Any.new([tool_entry, tool_entry]),
      } of String => JSON::Any
      provider.normalize_required_tool_choice(payload)
      payload["tool_choice"].as_s.should eq("any")
    end
  end

  describe "#build_tool_choice" do
    it "maps 'required' to Mistral's 'any' sentinel" do
      provider = configured_mistral
      provider.build_tool_choice("required").as_s.should eq("any")
    end

    it "delegates other choices to the OpenAI shaping" do
      provider = configured_mistral
      provider.build_tool_choice("auto").as_s.should eq("auto")
      named = provider.build_tool_choice("my_tool").as_h
      named["type"].as_s.should eq("function")
      named["function"].as_h["name"].as_s.should eq("my_tool")
    end
  end

  describe "#format_role" do
    it "uses the bare downcased role (no developer mapping)" do
      provider = configured_mistral
      provider.format_role(CrystalLLM::Role::System).should eq("system")
      provider.format_role(CrystalLLM::Role::User).should eq("user")
      provider.format_role(CrystalLLM::Role::Assistant).should eq("assistant")
    end
  end

  describe "#parse_completion_response (inherited)" do
    it "turns a Mistral completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "model": "mistral-large-latest",
        "choices": [
          {"message": {"role": "assistant", "content": "Bonjour!"}}
        ],
        "usage": {"prompt_tokens": 9, "completion_tokens": 3, "total_tokens": 12}
      }
      JSON
      provider = configured_mistral
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Bonjour!")
      message.model_id.should eq("mistral-large-latest")
      message.input_tokens.should eq(9)
      message.output_tokens.should eq(3)
      message.tool_call?.should be_false
    end

    it "parses tool calls from the message" do
      body = <<-JSON
      {
        "model": "mistral-large-latest",
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
      provider = configured_mistral
      message = provider.parse_completion_response(build_response(200, body))

      message.tool_call?.should be_true
      calls = message.tool_calls
      raise "no tool calls" unless calls
      calls.size.should eq(1)
      calls["call_1"].name.should eq("get_weather")
      calls["call_1"].arguments["city"].as_s.should eq("Paris")
    end
  end

  describe "#build_chunk (inherited)" do
    it "turns a Mistral streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "mistral-large-latest",
        "choices": [{"delta": {"content": "Bon"}}]
      }
      JSON
      provider = configured_mistral
      chunk = provider.build_chunk(data)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("mistral-large-latest")
      chunk.content.should eq("Bon")
    end
  end

  describe "#parse_list_models_response" do
    it "maps rows through the Mistral capabilities helper" do
      body = <<-JSON
      {
        "data": [
          {"id": "mistral-large-latest", "object": "model", "owned_by": "mistralai"},
          {"id": "pixtral-12b-2409", "object": "model", "owned_by": "mistralai"}
        ]
      }
      JSON
      provider = configured_mistral
      models = provider.parse_list_models_response(
        build_response(200, body), "mistral", CrystalLLM::Providers::Mistral::Capabilities
      )

      models.size.should eq(2)
      large = models[0]
      large.id.should eq("mistral-large-latest")
      large.name.should eq("Mistral Large")
      large.family.should eq("mistral-large")
      large.provider.should eq("mistral")
      large.context_window.should eq(32_768)
      large.max_output_tokens.should eq(8192)
      large.capabilities.should contain("function_calling")

      pixtral = models[1]
      pixtral.name.should eq("Pixtral 12B")
      pixtral.family.should eq("pixtral")
      pixtral.modalities.input.should contain("image")
      pixtral.capabilities.should contain("vision")
      pixtral.created_at.should_not be_nil
    end
  end

  describe "Capabilities" do
    it "classifies families, display names and modalities" do
      caps = CrystalLLM::Providers::Mistral::Capabilities
      caps.model_family("codestral-2501").should eq("codestral")
      caps.format_display_name("ministral-8b-latest").should eq("Ministral 8B")
      caps.supports_vision?("pixtral-12b").should be_true
      caps.supports_reasoning?("magistral-medium-latest").should be_true
      caps.supports_tools?("mistral-tiny-2312").should be_false
    end

    it "builds wire pricing consumable by Model::Pricing (zeros collapse to empty)" do
      # Mistral reports flat zero pricing; Model::Pricing treats an all-zero tier as
      # empty (faithful to ruby_llm), so the text_tokens prices read back as nil.
      caps = CrystalLLM::Providers::Mistral::Capabilities
      wire = caps.pricing_for("mistral-large-latest")
      wire.dig("text_tokens", "standard", "input_per_million").as_f.should eq(0.0)

      pricing = CrystalLLM::Model::Pricing.new(wire)
      pricing.text_tokens.input.should be_nil
      pricing.text_tokens.output.should be_nil
    end

    it "resolves release dates" do
      caps = CrystalLLM::Providers::Mistral::Capabilities
      caps.release_date_for("mistral-large-2411").should eq("2024-11-20")
      caps.release_date_for("totally-unknown-model").should be_nil
    end
  end

  describe "temperature normalization (inherited)" do
    it "passes Mistral temperatures through unchanged" do
      provider = configured_mistral
      provider.maybe_normalize_temperature(0.3, mistral_model).should eq(0.3)
    end
  end
end
