require "../spec_helper"
require "../../src/crystal_llm/providers/xai"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

private def configured_xai : CrystalLLM::Providers::XAI
  config = CrystalLLM::Configuration.new
  config.xai_api_key = "test"
  CrystalLLM::Providers::XAI.new(config)
end

private def grok_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "grok-3", name: "Grok 3", provider: "xai")
end

describe CrystalLLM::Providers::XAI do
  describe "Configuration reopen" do
    it "adds xai_api_key to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("xai_api_key")
    end

    it "reads xai_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("xai_api_key").should be_false
      config.xai_api_key = "test"
      config.configured?("xai_api_key").should be_true
      config["xai_api_key"]?.should eq("test")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("xai").should eq(CrystalLLM::Providers::XAI)
    end
  end

  describe "configuration requirements/options" do
    it "requires only xai_api_key" do
      CrystalLLM::Providers::XAI.configuration_requirements.should eq(["xai_api_key"])
      CrystalLLM::Providers::XAI.configuration_options.should eq(["xai_api_key"])
    end
  end

  describe "#api_base / #headers" do
    it "points at the xAI api base" do
      configured_xai.api_base.should eq("https://api.x.ai/v1")
    end

    it "builds a Bearer Authorization header from xai_api_key" do
      provider = configured_xai
      provider.headers["Authorization"].should eq("Bearer test")
      provider.headers["Content-Type"].should eq("application/json")
      provider.headers.has_key?("OpenAI-Organization").should be_false
    end
  end

  describe "#completion_url / #stream_url / #models_url" do
    it "reuses the OpenAI chat-completions paths" do
      provider = configured_xai
      provider.completion_url.should eq("chat/completions")
      provider.stream_url.should eq("chat/completions")
      provider.models_url.should eq("models")
    end
  end

  describe "#format_role" do
    it "keeps the system role (no developer swap)" do
      provider = configured_xai
      provider.format_role(CrystalLLM::Role::System).should eq("system")
      provider.format_role(CrystalLLM::Role::User).should eq("user")
      provider.format_role(CrystalLLM::Role::Assistant).should eq("assistant")
    end
  end

  describe "#render_payload" do
    it "produces the expected xAI chat JSON for a simple user message" do
      provider = configured_xai
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.5,
        model: grok_model,
        stream: false
      )

      payload["model"].as_s.should eq("grok-3")
      payload["stream"].as_bool.should be_false
      payload["temperature"].as_f.should eq(0.5)
      payload.has_key?("tools").should be_false

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      msgs[0].as_h["content"].as_s.should eq("hi")
    end

    it "adds stream_options when streaming and omits nil temperature" do
      provider = configured_xai
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: grok_model,
        stream: true
      )
      payload.has_key?("temperature").should be_false
      payload["stream"].as_bool.should be_true
      payload["stream_options"].as_h["include_usage"].as_bool.should be_true
    end
  end

  describe "#parse_completion_response" do
    it "turns an xAI completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "model": "grok-3",
        "choices": [
          {"message": {"role": "assistant", "content": "Hello from Grok!"}}
        ],
        "usage": {"prompt_tokens": 9, "completion_tokens": 4, "total_tokens": 13}
      }
      JSON
      provider = configured_xai
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello from Grok!")
      message.model_id.should eq("grok-3")
      message.input_tokens.should eq(9)
      message.output_tokens.should eq(4)
      message.tool_call?.should be_false
    end

    it "raises on an error body" do
      body = %({"error": {"message": "invalid key", "type": "invalid_request_error"}})
      provider = configured_xai
      expect_raises(CrystalLLM::Error, "invalid key") do
        provider.parse_completion_response(build_response(401, body))
      end
    end
  end

  describe "#build_chunk" do
    it "turns an xAI streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "grok-3",
        "choices": [{"delta": {"content": "Hel"}}]
      }
      JSON
      provider = configured_xai
      chunk = provider.build_chunk(data)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("grok-3")
      chunk.content.should eq("Hel")
    end
  end

  describe "#parse_list_models_response" do
    it "classifies grok models with family/modalities/capabilities" do
      body = <<-JSON
      {
        "data": [
          {"id": "grok-4-0709", "object": "model", "created": 1700000000, "owned_by": "xai"},
          {"id": "grok-2-image-1212", "object": "model", "owned_by": "xai"},
          {"id": "grok-3-mini", "object": "model"}
        ]
      }
      JSON
      provider = configured_xai
      models = provider.parse_list_models_response(
        build_response(200, body), "xai", CrystalLLM::Providers::XAI.capabilities
      )

      models.size.should eq(3)

      vision = models[0]
      vision.id.should eq("grok-4-0709")
      vision.name.should eq("Grok 4 0709")
      vision.family.should eq("grok")
      vision.modalities.input.should contain("image")
      vision.capabilities.should contain("vision")
      vision.capabilities.should contain("reasoning")
      vision.capabilities.should contain("function_calling")

      image = models[1]
      image.id.should eq("grok-2-image-1212")
      image.modalities.output.should eq(["image"])
      image.capabilities.should be_empty

      mini = models[2]
      mini.id.should eq("grok-3-mini")
      mini.capabilities.should contain("reasoning")
      mini.modalities.input.should eq(["text"])
    end
  end

  describe "#capabilities" do
    it "inherits the OpenAI Capabilities helper for the abstract hook" do
      CrystalLLM::Providers::XAI.capabilities.should eq(CrystalLLM::Providers::OpenAI::Capabilities)
    end
  end
end
