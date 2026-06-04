require "../spec_helper"
require "../../src/crystal_llm/providers/ollama"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

private def configured_ollama : CrystalLLM::Providers::Ollama
  config = CrystalLLM::Configuration.new
  config.ollama_api_base = "http://localhost:11434/v1"
  CrystalLLM::Providers::Ollama.new(config)
end

private def ollama_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "llama3.2", name: "llama3.2", provider: "ollama")
end

describe CrystalLLM::Providers::Ollama do
  describe "Configuration reopen" do
    it "adds ollama options to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("ollama_api_base")
      CrystalLLM::Configuration.options.should contain("ollama_api_key")
    end

    it "reads ollama_api_base via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("ollama_api_base").should be_false
      config.ollama_api_base = "http://localhost:11434/v1"
      config.configured?("ollama_api_base").should be_true
      config["ollama_api_base"]?.should eq("http://localhost:11434/v1")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("ollama").should eq(CrystalLLM::Providers::Ollama)
    end
  end

  describe "configuration metadata" do
    it "requires ollama_api_base and lists both options" do
      CrystalLLM::Providers::Ollama.configuration_requirements.should eq(["ollama_api_base"])
      CrystalLLM::Providers::Ollama.configuration_options.should eq(["ollama_api_base", "ollama_api_key"])
    end

    it "is a local provider" do
      CrystalLLM::Providers::Ollama.local?.should be_true
    end

    it "raises at construction when ollama_api_base is missing" do
      config = CrystalLLM::Configuration.new
      expect_raises(CrystalLLM::ConfigurationError, "ollama_api_base") do
        CrystalLLM::Providers::Ollama.new(config)
      end
    end
  end

  describe "#api_base / #headers" do
    it "uses the configured ollama_api_base with no default" do
      configured_ollama.api_base.should eq("http://localhost:11434/v1")
    end

    it "emits no Authorization header without an api key" do
      configured_ollama.headers.has_key?("Authorization").should be_false
    end

    it "emits a bearer Authorization header when an api key is set" do
      config = CrystalLLM::Configuration.new
      config.ollama_api_base = "http://localhost:11434/v1"
      config.ollama_api_key = "test"
      CrystalLLM::Providers::Ollama.new(config).headers["Authorization"].should eq("Bearer test")
    end
  end

  describe "#completion_url / #stream_url / #models_url" do
    it "inherits the OpenAI-compatible endpoints" do
      provider = configured_ollama
      provider.completion_url.should eq("chat/completions")
      provider.stream_url.should eq("chat/completions")
      provider.models_url.should eq("models")
    end
  end

  describe "#format_role" do
    it "returns the bare downcased role with no system->developer remap" do
      provider = configured_ollama
      provider.format_role(CrystalLLM::Role::System).should eq("system")
      provider.format_role(CrystalLLM::Role::User).should eq("user")
      provider.format_role(CrystalLLM::Role::Assistant).should eq("assistant")
    end
  end

  describe "#render_payload" do
    it "produces the expected Ollama chat JSON for a simple user message + model id" do
      provider = configured_ollama
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: ollama_model,
        stream: false
      )

      payload["model"].as_s.should eq("llama3.2")
      payload["stream"].as_bool.should be_false
      payload["temperature"].as_f.should eq(0.7)
      payload.has_key?("tools").should be_false

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      msgs[0].as_h["content"].as_s.should eq("hi")
    end

    it "formats a system message with role 'system' (no developer remap)" do
      provider = configured_ollama
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: "be brief")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: ollama_model,
        stream: false
      )
      payload["messages"].as_a[0].as_h["role"].as_s.should eq("system")
    end
  end

  describe "#parse_completion_response" do
    it "turns an Ollama completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "model": "llama3.2",
        "choices": [
          {"message": {"role": "assistant", "content": "Hello there!"}}
        ],
        "usage": {"prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17}
      }
      JSON
      provider = configured_ollama
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello there!")
      message.model_id.should eq("llama3.2")
      message.input_tokens.should eq(12)
      message.output_tokens.should eq(5)
      message.tool_call?.should be_false
    end
  end

  describe "#build_chunk" do
    it "turns an Ollama streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "llama3.2",
        "choices": [{"delta": {"content": "Hel"}}]
      }
      JSON
      provider = configured_ollama
      chunk = provider.build_chunk(data)
      chunk.should be_a(CrystalLLM::Chunk)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("llama3.2")
      chunk.content.should eq("Hel")
    end
  end

  describe "#parse_list_models_response" do
    it "maps the OpenAI-compatible model list into ollama-family Model::Info" do
      body = <<-JSON
      {
        "data": [
          {"id": "llama3.2", "object": "model", "created": 1700000000, "owned_by": "library"}
        ]
      }
      JSON
      provider = configured_ollama
      models = provider.parse_list_models_response(
        build_response(200, body), "ollama", CrystalLLM::Providers::Ollama.capabilities
      )

      models.size.should eq(1)
      model = models[0]
      model.id.should eq("llama3.2")
      model.name.should eq("llama3.2")
      model.provider.should eq("ollama")
      model.family.should eq("ollama")
      model.created_at.should eq(Time.unix(1700000000))
      model.modalities.input.should eq(%w[text image])
      model.modalities.output.should eq(%w[text])
      model.capabilities.should eq(%w[streaming function_calling structured_output vision])
      model.metadata["owned_by"].as_s.should eq("library")
    end

    it "returns an empty list for an empty body" do
      provider = configured_ollama
      provider.parse_list_models_response(
        build_response(200, ""), "ollama", CrystalLLM::Providers::Ollama.capabilities
      ).should be_empty
    end
  end

  describe "capabilities" do
    it "reports the Ollama capabilities helper" do
      CrystalLLM::Providers::Ollama.capabilities.should eq(CrystalLLM::Providers::Ollama::Capabilities)
    end

    it "reports tool_choice / tool_parallel_control as unsupported" do
      caps = CrystalLLM::Providers::Ollama::Capabilities
      caps.supports_tool_choice?("llama3.2").should be_false
      caps.supports_tool_parallel_control?("llama3.2").should be_false
    end
  end
end
