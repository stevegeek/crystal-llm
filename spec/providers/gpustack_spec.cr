require "../spec_helper"
require "../../src/crystal_llm/providers/gpustack"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://gpustack.test")
  )
end

private def configured_gpustack : CrystalLLM::Providers::GPUStack
  config = CrystalLLM::Configuration.new
  config.gpustack_api_base = "http://gpustack.local/v1"
  config.gpustack_api_key = "test"
  CrystalLLM::Providers::GPUStack.new(config)
end

private def llama_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "llama3", name: "llama3", provider: "gpustack")
end

describe CrystalLLM::Providers::GPUStack do
  describe "Configuration reopen" do
    it "adds gpustack options to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("gpustack_api_base")
      CrystalLLM::Configuration.options.should contain("gpustack_api_key")
    end

    it "reads gpustack_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("gpustack_api_key").should be_false
      config.gpustack_api_key = "test"
      config.configured?("gpustack_api_key").should be_true
      config["gpustack_api_key"]?.should eq("test")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("gpustack").should eq(CrystalLLM::Providers::GPUStack)
    end
  end

  describe "configuration_requirements / configuration_options" do
    it "requires both api_base and api_key (task contract)" do
      CrystalLLM::Providers::GPUStack.configuration_requirements.should eq(["gpustack_api_base", "gpustack_api_key"])
      CrystalLLM::Providers::GPUStack.configuration_options.should eq(["gpustack_api_base", "gpustack_api_key"])
    end

    it "reports local?" do
      CrystalLLM::Providers::GPUStack.local?.should be_true
    end
  end

  describe "#api_base / #headers" do
    it "uses the configured gpustack_api_base and bearer header" do
      provider = configured_gpustack
      provider.api_base.should eq("http://gpustack.local/v1")
      provider.headers["Authorization"].should eq("Bearer test")
    end
  end

  describe "#completion_url / #stream_url (inherited)" do
    it "targets chat/completions" do
      provider = configured_gpustack
      provider.completion_url.should eq("chat/completions")
      provider.stream_url.should eq("chat/completions")
    end
  end

  describe "#render_payload" do
    it "produces the expected OpenAI-compatible chat JSON for [user \"hi\"] + a model id" do
      provider = configured_gpustack
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: llama_model,
        stream: false
      )

      payload["model"].as_s.should eq("llama3")
      payload["stream"].as_bool.should be_false
      payload["temperature"].as_f.should eq(0.7)
      payload.has_key?("tools").should be_false

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      msgs[0].as_h["content"].as_s.should eq("hi")
    end
  end

  describe "#format_role" do
    it "uses the bare lowercase role string (system stays \"system\", not \"developer\")" do
      provider = configured_gpustack
      provider.format_role(CrystalLLM::Role::System).should eq("system")
      provider.format_role(CrystalLLM::Role::User).should eq("user")
      provider.format_role(CrystalLLM::Role::Assistant).should eq("assistant")
    end
  end

  describe "#parse_completion_response" do
    it "turns a GPUStack/OpenAI completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "model": "llama3",
        "choices": [
          {"message": {"role": "assistant", "content": "Hello from GPUStack!"}}
        ],
        "usage": {"prompt_tokens": 9, "completion_tokens": 4, "total_tokens": 13}
      }
      JSON
      provider = configured_gpustack
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello from GPUStack!")
      message.model_id.should eq("llama3")
      message.input_tokens.should eq(9)
      message.output_tokens.should eq(4)
      message.tool_call?.should be_false
    end
  end

  describe "#build_chunk (inherited)" do
    it "turns a streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "llama3",
        "choices": [{"delta": {"content": "Hel"}}]
      }
      JSON
      provider = configured_gpustack
      chunk = provider.build_chunk(data)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("llama3")
      chunk.content.should eq("Hel")
    end
  end

  describe "#models_url / #parse_list_models_response" do
    it "targets models and parses the GPUStack {items:[...]} payload" do
      provider = configured_gpustack
      provider.models_url.should eq("models")

      body = <<-JSON
      {
        "items": [
          {
            "name": "qwen2.5",
            "created_at": "2025-01-02 03:04:05",
            "description": "a chat model",
            "source": "huggingface",
            "categories": ["llm"],
            "meta": {"n_ctx": 8192, "support_tool_calls": true, "support_vision": true}
          },
          {
            "name": "bge-embed",
            "categories": ["embedding"],
            "meta": {"n_ctx": 512}
          }
        ]
      }
      JSON

      models = provider.parse_list_models_response(
        build_response(200, body),
        "gpustack",
        CrystalLLM::Providers::GPUStack::Capabilities
      )

      models.size.should eq(2)

      chat = models[0]
      chat.id.should eq("qwen2.5")
      chat.provider.should eq("gpustack")
      chat.family.should eq("gpustack")
      chat.context_window.should eq(8192)
      chat.max_output_tokens.should eq(8192)
      chat.capabilities.should contain("streaming")
      chat.capabilities.should contain("function_calling")
      chat.capabilities.should contain("vision")
      chat.capabilities.should contain("structured_output")
      chat.capabilities.should contain("json_mode")
      chat.modalities.input.should contain("text")
      chat.modalities.input.should contain("image")
      chat.modalities.output.should contain("text")
      chat.created_at.should_not be_nil

      embed = models[1]
      embed.id.should eq("bge-embed")
      embed.modalities.output.should contain("embeddings")
      embed.capabilities.should_not contain("streaming")
    end

    it "returns [] for an empty body" do
      provider = configured_gpustack
      provider.parse_list_models_response(
        build_response(200, ""),
        "gpustack",
        CrystalLLM::Providers::GPUStack::Capabilities
      ).should be_empty
    end
  end

  describe "Capabilities" do
    it "reports tool_choice / parallel tool control unsupported" do
      caps = CrystalLLM::Providers::GPUStack::Capabilities
      caps.supports_tool_choice?("anything").should be_false
      caps.supports_tool_parallel_control?("anything").should be_false
    end

    it "is the provider's capabilities class" do
      CrystalLLM::Providers::GPUStack.capabilities.should eq(CrystalLLM::Providers::GPUStack::Capabilities)
    end
  end
end
