require "../spec_helper"
require "../../src/crystal_llm/providers/perplexity"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_perplexity : CrystalLLM::Providers::Perplexity
  config = CrystalLLM::Configuration.new
  config.perplexity_api_key = "test"
  CrystalLLM::Providers::Perplexity.new(config)
end

private def sonar_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "sonar", name: "sonar", provider: "perplexity")
end

describe CrystalLLM::Providers::Perplexity do
  describe "Configuration reopen" do
    it "adds perplexity_api_key to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("perplexity_api_key")
    end

    it "reads perplexity_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("perplexity_api_key").should be_false
      config.perplexity_api_key = "pk-x"
      config.configured?("perplexity_api_key").should be_true
      config["perplexity_api_key"]?.should eq("pk-x")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("perplexity").should eq(CrystalLLM::Providers::Perplexity)
    end
  end

  describe "configuration requirements/options" do
    it "requires the perplexity api key" do
      CrystalLLM::Providers::Perplexity.configuration_requirements.should eq(["perplexity_api_key"])
      # ruby_llm bf152ec8 adds perplexity_api_base as an (optional) configuration option.
      CrystalLLM::Providers::Perplexity.configuration_options.should eq(["perplexity_api_key", "perplexity_api_base"])
    end
  end

  describe "#api_base / #headers" do
    it "uses the perplexity api base and builds Authorization + Content-Type headers" do
      provider = configured_perplexity
      provider.api_base.should eq("https://api.perplexity.ai")
      provider.headers["Authorization"].should eq("Bearer test")
      provider.headers["Content-Type"].should eq("application/json")
    end
  end

  describe "#completion_url / #stream_url" do
    it "uses the OpenAI-compatible chat/completions path" do
      provider = configured_perplexity
      provider.completion_url.should eq("chat/completions")
      provider.stream_url.should eq("chat/completions")
    end
  end

  describe "#render_payload" do
    it "produces the expected chat JSON for a simple user message" do
      provider = configured_perplexity
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: sonar_model,
        stream: false
      )

      payload["model"].as_s.should eq("sonar")
      payload["stream"].as_bool.should be_false
      payload["temperature"].as_f.should eq(0.7)
      payload.has_key?("tools").should be_false

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      msgs[0].as_h["content"].as_s.should eq("hi")
    end

    it "renders the system role as 'system' (no developer remap)" do
      provider = configured_perplexity
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: "be terse")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: sonar_model,
        stream: false
      )
      payload["messages"].as_a[0].as_h["role"].as_s.should eq("system")
    end
  end

  describe "#parse_completion_response" do
    it "turns a completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "model": "sonar",
        "choices": [
          {"message": {"role": "assistant", "content": "Hello from Sonar"}}
        ],
        "usage": {"prompt_tokens": 9, "completion_tokens": 4, "total_tokens": 13}
      }
      JSON
      provider = configured_perplexity
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello from Sonar")
      message.model_id.should eq("sonar")
      message.input_tokens.should eq(9)
      message.output_tokens.should eq(4)
    end

    it "raises on a JSON error body" do
      body = %({"error": {"message": "bad key", "type": "invalid_request_error"}})
      provider = configured_perplexity
      expect_raises(CrystalLLM::Error, "bad key") do
        provider.parse_completion_response(build_response(401, body))
      end
    end
  end

  describe "#build_chunk" do
    it "turns a streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "sonar",
        "choices": [{"delta": {"content": "Hel"}}]
      }
      JSON
      provider = configured_perplexity
      chunk = provider.build_chunk(data)
      chunk.should be_a(CrystalLLM::Chunk)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("sonar")
      chunk.content.should eq("Hel")
    end
  end

  describe "#parse_list_models_response" do
    it "returns the static Sonar model set, ignoring the response body" do
      provider = configured_perplexity
      models = provider.parse_list_models_response(
        build_response(200, ""), "perplexity", CrystalLLM::Providers::Perplexity::Capabilities
      )
      ids = models.map(&.id)
      ids.should eq(%w[sonar sonar-pro sonar-reasoning sonar-reasoning-pro sonar-deep-research])
      sonar = models.first
      sonar.provider.should eq("perplexity")
      sonar.context_window.should eq(128_000)
      sonar.max_output_tokens.should eq(4_096)
    end
  end

  describe "#parse_error (HTML auth errors)" do
    it "extracts the <title> text and strips a leading status code" do
      provider = configured_perplexity
      html = "<html><head><title>401 Authorization Required</title></head><body>nope</body></html>"
      provider.parse_error(build_response(401, html)).should eq("Authorization Required")
    end

    it "falls back to JSON extraction for non-HTML bodies" do
      provider = configured_perplexity
      json = %({"error": {"message": "rate limited"}})
      provider.parse_error(build_response(429, json)).should eq("rate limited")
    end
  end

  describe "Capabilities" do
    it "classifies model families, windows, and capabilities" do
      caps = CrystalLLM::Providers::Perplexity::Capabilities
      caps.model_family("sonar").should eq("sonar")
      caps.model_family("sonar-deep-research").should eq("sonar_deep_research")
      caps.context_window_for("sonar-pro").should eq(200_000)
      caps.context_window_for("sonar").should eq(128_000)
      caps.max_tokens_for("sonar-pro").should eq(8_192)
      caps.max_tokens_for("sonar").should eq(4_096)
      caps.critical_capabilities_for("sonar").should contain("vision")
      caps.critical_capabilities_for("sonar-reasoning").should contain("reasoning")
      caps.supports_tool_choice?("sonar").should be_false
      caps.supports_tool_parallel_control?("sonar").should be_false
    end

    it "builds wire pricing consumable by Model::Pricing (incl. reasoning output)" do
      caps = CrystalLLM::Providers::Perplexity::Capabilities
      pricing = CrystalLLM::Model::Pricing.new(caps.pricing_for("sonar-pro"))
      pricing.text_tokens.input.should eq(3.0)
      pricing.text_tokens.output.should eq(15.0)

      deep = caps.pricing_for("sonar-deep-research")
      standard = deep["text_tokens"].as_h["standard"].as_h
      standard["reasoning_output_per_million"].as_f.should eq(3.0)
    end
  end
end
