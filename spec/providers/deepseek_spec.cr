require "../spec_helper"
require "../../src/crystal_llm/providers/deepseek"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

private def configured_deepseek : CrystalLLM::Providers::DeepSeek
  config = CrystalLLM::Configuration.new
  config.deepseek_api_key = "test"
  CrystalLLM::Providers::DeepSeek.new(config)
end

private def deepseek_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "deepseek-chat", name: "DeepSeek Chat", provider: "deepseek")
end

describe CrystalLLM::Providers::DeepSeek do
  describe "Configuration reopen" do
    it "adds deepseek_api_key/base to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("deepseek_api_key")
      CrystalLLM::Configuration.options.should contain("deepseek_api_base")
    end

    it "reads deepseek_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("deepseek_api_key").should be_false
      config.deepseek_api_key = "test"
      config.configured?("deepseek_api_key").should be_true
      config["deepseek_api_key"]?.should eq("test")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("deepseek").should eq(CrystalLLM::Providers::DeepSeek)
    end
  end

  describe "configuration requirements/options" do
    it "requires only deepseek_api_key" do
      CrystalLLM::Providers::DeepSeek.configuration_requirements.should eq(["deepseek_api_key"])
      CrystalLLM::Providers::DeepSeek.configuration_options.should eq(["deepseek_api_key", "deepseek_api_base"])
    end
  end

  describe "#api_base / #headers" do
    it "defaults api_base (no /v1) and builds Authorization header" do
      provider = configured_deepseek
      provider.api_base.should eq("https://api.deepseek.com")
      provider.headers["Authorization"].should eq("Bearer test")
      provider.headers.has_key?("OpenAI-Organization").should be_false
    end

    it "honors a configured deepseek_api_base" do
      config = CrystalLLM::Configuration.new
      config.deepseek_api_key = "test"
      config.deepseek_api_base = "https://proxy.test"
      CrystalLLM::Providers::DeepSeek.new(config).api_base.should eq("https://proxy.test")
    end
  end

  describe "URLs inherited from OpenAI" do
    it "uses the OpenAI completion/models paths" do
      provider = configured_deepseek
      provider.completion_url.should eq("chat/completions")
      provider.stream_url.should eq("chat/completions")
      provider.models_url.should eq("models")
    end
  end

  describe "#render_payload" do
    it "produces the expected DeepSeek chat JSON for a simple user message" do
      provider = configured_deepseek
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: deepseek_model,
        stream: false
      )

      payload["model"].as_s.should eq("deepseek-chat")
      payload["stream"].as_bool.should be_false
      payload["temperature"].as_f.should eq(0.7)
      payload.has_key?("tools").should be_false
      payload.has_key?("stream_options").should be_false

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      msgs[0].as_h["content"].as_s.should eq("hi")
    end

    it "formats a system message with a plain 'system' role (no developer remap)" do
      provider = configured_deepseek
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: "be terse")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: deepseek_model,
        stream: false
      )
      payload["messages"].as_a[0].as_h["role"].as_s.should eq("system")
    end

    it "omits temperature when nil and adds stream_options when streaming" do
      provider = configured_deepseek
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: deepseek_model,
        stream: true
      )
      payload.has_key?("temperature").should be_false
      payload["stream"].as_bool.should be_true
      payload["stream_options"].as_h["include_usage"].as_bool.should be_true
    end
  end

  describe "#parse_completion_response" do
    it "turns a DeepSeek completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "model": "deepseek-chat",
        "choices": [
          {"message": {"role": "assistant", "content": "Hello there!"}}
        ],
        "usage": {"prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17}
      }
      JSON
      provider = configured_deepseek
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello there!")
      message.model_id.should eq("deepseek-chat")
      message.input_tokens.should eq(12)
      message.output_tokens.should eq(5)
      message.tool_call?.should be_false
    end

    it "honors DeepSeek's prompt_cache_hit/miss token accounting" do
      body = <<-JSON
      {
        "model": "deepseek-chat",
        "choices": [{"message": {"role": "assistant", "content": "hi"}}],
        "usage": {
          "prompt_tokens": 100, "completion_tokens": 5, "total_tokens": 105,
          "prompt_cache_hit_tokens": 80, "prompt_cache_miss_tokens": 20
        }
      }
      JSON
      provider = configured_deepseek
      message = provider.parse_completion_response(build_response(200, body))
      message.input_tokens.should eq(20)
      message.cached_tokens.should eq(80)
    end

    it "raises on an error body" do
      body = %({"error": {"message": "bad key", "type": "invalid_request_error"}})
      provider = configured_deepseek
      expect_raises(CrystalLLM::Error, "bad key") do
        provider.parse_completion_response(build_response(401, body))
      end
    end
  end

  describe "#build_chunk" do
    it "turns a DeepSeek streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "deepseek-chat",
        "choices": [{"delta": {"content": "Hel"}}]
      }
      JSON
      provider = configured_deepseek
      chunk = provider.build_chunk(data)
      chunk.should be_a(CrystalLLM::Chunk)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("deepseek-chat")
      chunk.content.should eq("Hel")
    end
  end

  describe "#parse_list_models_response" do
    it "parses DeepSeek's OpenAI-shaped model list" do
      body = <<-JSON
      {"object": "list", "data": [
        {"id": "deepseek-chat", "object": "model", "owned_by": "deepseek"},
        {"id": "deepseek-reasoner", "object": "model", "owned_by": "deepseek"}
      ]}
      JSON
      provider = configured_deepseek
      models = provider.parse_list_models_response(
        build_response(200, body), "deepseek",
        CrystalLLM::Providers::DeepSeek.capabilities
      )
      models.size.should eq(2)
      models.map(&.id).should eq(["deepseek-chat", "deepseek-reasoner"])
      models[0].provider.should eq("deepseek")
    end
  end

  describe "Capabilities" do
    it "reports tool_choice support and no parallel-tool control" do
      caps = CrystalLLM::Providers::DeepSeek::Capabilities
      caps.supports_tool_choice?("deepseek-chat").should be_true
      caps.supports_tool_parallel_control?("deepseek-chat").should be_false
    end

    it "is the class returned by .capabilities" do
      CrystalLLM::Providers::DeepSeek.capabilities.should eq(CrystalLLM::Providers::DeepSeek::Capabilities)
    end

    # ported from lib/ruby_llm/providers/deepseek/capabilities.rb @ ruby_llm
    # 1.16.0 (commit 3f27b864) — context_window_for/max_tokens_for are fixed
    # constants (DeepSeek's registry rides on models.json, not per-model logic;
    # these back-fill a live list_models response that omits limits/pricing).
    it "reports fixed context_window/max_tokens defaults regardless of model_id" do
      caps = CrystalLLM::Providers::DeepSeek::Capabilities
      caps.context_window_for("deepseek-chat").should eq(1_000_000)
      caps.context_window_for("deepseek-v4-pro").should eq(1_000_000)
      caps.max_tokens_for("deepseek-chat").should eq(384_000)
      caps.max_tokens_for("deepseek-v4-pro").should eq(384_000)
    end

    it "critical_capabilities_for: deepseek-chat gets only function_calling" do
      caps = CrystalLLM::Providers::DeepSeek::Capabilities
      caps.critical_capabilities_for("deepseek-chat").should eq(%w[function_calling])
    end

    it "critical_capabilities_for: deepseek-reasoner gets function_calling + reasoning (not structured_output)" do
      caps = CrystalLLM::Providers::DeepSeek::Capabilities
      caps.critical_capabilities_for("deepseek-reasoner").should eq(%w[function_calling reasoning])
    end

    it "critical_capabilities_for: deepseek-v4-* models get all three critical capabilities" do
      caps = CrystalLLM::Providers::DeepSeek::Capabilities
      caps.critical_capabilities_for("deepseek-v4-pro").should eq(%w[function_calling structured_output reasoning])
      caps.critical_capabilities_for("deepseek-v4-lite").should eq(%w[function_calling structured_output reasoning])
    end

    it "pricing_for: DEFAULT_PRICES for non-pro models" do
      caps = CrystalLLM::Providers::DeepSeek::Capabilities
      pricing = CrystalLLM::Model::Pricing.new(caps.pricing_for("deepseek-chat"))
      pricing.text_tokens.input.should eq(0.14)
      pricing.text_tokens.output.should eq(0.28)
      pricing.text_tokens.cache_read_input.should eq(0.0028)
    end

    it "pricing_for: PRO_PRICES for deepseek-v4-pro only" do
      caps = CrystalLLM::Providers::DeepSeek::Capabilities
      pricing = CrystalLLM::Model::Pricing.new(caps.pricing_for("deepseek-v4-pro"))
      pricing.text_tokens.input.should eq(0.435)
      pricing.text_tokens.output.should eq(0.87)
      pricing.text_tokens.cache_read_input.should eq(0.003625)

      # deepseek-v4-lite is NOT deepseek-v4-pro -> gets DEFAULT_PRICES, not PRO_PRICES.
      lite_pricing = CrystalLLM::Model::Pricing.new(caps.pricing_for("deepseek-v4-lite"))
      lite_pricing.text_tokens.input.should eq(0.14)
    end
  end
end
