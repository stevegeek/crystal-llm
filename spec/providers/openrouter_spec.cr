require "../spec_helper"
require "../../src/crystal_llm/provider_completion"
require "../../src/crystal_llm/providers/openrouter"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_openrouter : CrystalLLM::Providers::OpenRouter
  config = CrystalLLM::Configuration.new
  config.openrouter_api_key = "test"
  CrystalLLM::Providers::OpenRouter.new(config)
end

private def or_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "openai/gpt-4o", name: "GPT-4o", provider: "openrouter")
end

describe CrystalLLM::Providers::OpenRouter do
  describe "Configuration reopen" do
    it "adds openrouter options to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("openrouter_api_key")
      CrystalLLM::Configuration.options.should contain("openrouter_api_base")
    end

    it "reads openrouter_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("openrouter_api_key").should be_false
      config.openrouter_api_key = "test"
      config.configured?("openrouter_api_key").should be_true
      config["openrouter_api_key"]?.should eq("test")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("openrouter").should eq(CrystalLLM::Providers::OpenRouter)
    end
  end

  describe "#api_base / #headers" do
    it "defaults api_base and builds Authorization header" do
      provider = configured_openrouter
      provider.api_base.should eq("https://openrouter.ai/api/v1")
      provider.headers["Authorization"].should eq("Bearer test")
    end

    it "honors a configured openrouter_api_base" do
      config = CrystalLLM::Configuration.new
      config.openrouter_api_key = "test"
      config.openrouter_api_base = "https://proxy.test/v1"
      CrystalLLM::Providers::OpenRouter.new(config).api_base.should eq("https://proxy.test/v1")
    end
  end

  describe "configuration_requirements" do
    it "requires openrouter_api_key" do
      CrystalLLM::Providers::OpenRouter.configuration_requirements.should eq(["openrouter_api_key"])
      CrystalLLM::Providers::OpenRouter.configuration_options.should contain("openrouter_api_base")
    end
  end

  describe "#render_payload" do
    it "produces the expected OpenRouter chat JSON for a simple user message" do
      provider = configured_openrouter
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: or_model,
        stream: false
      )

      payload["model"].as_s.should eq("openai/gpt-4o")
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
      provider = configured_openrouter
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: or_model,
        stream: true
      )
      payload.has_key?("temperature").should be_false
      payload["stream"].as_bool.should be_true
      payload["stream_options"].as_h["include_usage"].as_bool.should be_true
    end

    it "emits a reasoning object (not reasoning_effort) for a thinking config" do
      provider = configured_openrouter
      thinking = CrystalLLM::Thinking::Config.new(effort: "high")
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: or_model,
        stream: false,
        thinking: thinking
      )
      payload.has_key?("reasoning_effort").should be_false
      payload["reasoning"].as_h["effort"].as_s.should eq("high")
    end

    it "adds a response_format from a schema envelope and strips nested strict" do
      provider = configured_openrouter
      schema = JSON.parse(%({"name":"person","schema":{"type":"object","strict":false},"strict":true}))
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: or_model,
        stream: false,
        schema: schema
      )
      rf = payload["response_format"].as_h
      rf["type"].as_s.should eq("json_schema")
      js = rf["json_schema"].as_h
      js["name"].as_s.should eq("person")
      js["strict"].as_bool.should be_true
      js["schema"].as_h.has_key?("strict").should be_false
    end
  end

  describe "#parse_completion_response" do
    it "turns an OpenRouter completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "model": "openai/gpt-4o",
        "choices": [
          {"message": {"role": "assistant", "content": "Hello there!"}}
        ],
        "usage": {"prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17}
      }
      JSON
      provider = configured_openrouter
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello there!")
      message.model_id.should eq("openai/gpt-4o")
      message.input_tokens.should eq(12)
      message.output_tokens.should eq(5)
      message.tool_call?.should be_false
    end

    it "parses tool calls from the message" do
      body = <<-JSON
      {
        "model": "openai/gpt-4o",
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
      provider = configured_openrouter
      message = provider.parse_completion_response(build_response(200, body))

      message.tool_call?.should be_true
      calls = message.tool_calls
      raise "no tool calls" unless calls
      calls.size.should eq(1)
      calls["call_1"].name.should eq("get_weather")
      calls["call_1"].arguments["city"].as_s.should eq("Paris")
    end

    it "raises on an error body" do
      body = %({"error": {"message": "no credits", "type": "invalid_request_error"}})
      provider = configured_openrouter
      expect_raises(CrystalLLM::Error, "no credits") do
        provider.parse_completion_response(build_response(402, body))
      end
    end

    # ruby_llm 1.16.0 / 32f70eb3: `parse_completion_response` guarded against an
    # *empty* body (`data.empty?`) but crashed on a *nil* body (Faraday's JSON
    # middleware can leave `response.body` nil); the fix widened the guard to
    # `data.nil? || data.empty?` and returns nil gracefully either way.
    #
    # `parse_completion_response` here is inherited unchanged from OpenAI
    # (documented at the top of openai/chat.cr — identical wire shape); OpenRouter
    # has no override in this port. `Crest::Response#body` (crest/response.cr,
    # `delegate body, to: http_client_res`) is a non-nilable `String` — there is no
    # Crystal equivalent of Faraday's nilable body, so the `data.nil?` half of the
    # upstream fix is structurally unreachable here. `Message` is also non-nilable
    # in this port (ruby_llm's parse_completion_response can return nil; the port's
    # signature can't), so "return nil gracefully" becomes "raise a CrystalLLM::Error
    # gracefully" instead of returning — verifying that's still true (no unhandled
    # JSON::ParseException / nil-deref crash) rather than re-porting a nil-body
    # guard that can't occur.
    it "raises a graceful error instead of crashing on an empty response body" do
      provider = configured_openrouter
      expect_raises(CrystalLLM::Error, "Empty response from OpenAI") do
        provider.parse_completion_response(build_response(200, ""))
      end
    end

    it "raises a graceful error instead of crashing when the response has no choices" do
      body = %({"model": "openai/gpt-4o", "usage": {"prompt_tokens": 1, "completion_tokens": 0, "total_tokens": 1}})
      provider = configured_openrouter
      expect_raises(CrystalLLM::Error, "OpenAI response had no message") do
        provider.parse_completion_response(build_response(200, body))
      end
    end

    it "attaches thinking from a reasoning String" do
      body = <<-JSON
      {
        "model": "anthropic/claude-3.7-sonnet",
        "choices": [
          {"message": {"role": "assistant", "content": "Answer.", "reasoning": "I reasoned."}}
        ],
        "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}
      }
      JSON
      message = configured_openrouter.parse_completion_response(build_response(200, body))
      message.content.should eq("Answer.")
      thinking = message.thinking.should_not be_nil
      thinking.text.should eq("I reasoned.")
    end

    it "attaches thinking text + signature from reasoning_details" do
      body = <<-JSON
      {
        "model": "anthropic/claude-3.7-sonnet",
        "choices": [
          {"message": {"role": "assistant", "content": "Answer.",
            "reasoning_details": [
              {"type": "reasoning.text", "text": "First. ", "signature": "or-sig"},
              {"type": "reasoning.summary", "summary": "Second."}
            ]}}
        ],
        "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}
      }
      JSON
      message = configured_openrouter.parse_completion_response(build_response(200, body))
      thinking = message.thinking.should_not be_nil
      thinking.text.should eq("First. Second.")
      thinking.signature.should eq("or-sig")
    end

    it "reads an encrypted-reasoning signature when no text is present" do
      body = <<-JSON
      {
        "model": "anthropic/claude-3.7-sonnet",
        "choices": [
          {"message": {"role": "assistant", "content": "Answer.",
            "reasoning_details": [
              {"type": "reasoning.encrypted", "data": "enc-sig"}
            ]}}
        ],
        "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}
      }
      JSON
      message = configured_openrouter.parse_completion_response(build_response(200, body))
      thinking = message.thinking.should_not be_nil
      thinking.text.should be_nil
      thinking.signature.should eq("enc-sig")
    end
  end

  describe "outbound thinking (reasoning_details)" do
    it "re-emits thinking as reasoning_details on an assistant message" do
      provider = configured_openrouter
      assistant = CrystalLLM::Message.new(
        role: CrystalLLM::Role::Assistant, content: "Answer.",
        thinking: CrystalLLM::Thinking.new(text: "my reasoning", signature: "sig-z")
      )
      formatted = provider.format_messages([assistant])
      entry = formatted[0].as_h
      details = entry["reasoning_details"].as_a
      details.size.should eq(1)
      detail = details[0].as_h
      detail["type"].as_s.should eq("reasoning.text")
      detail["text"].as_s.should eq("my reasoning")
      detail["signature"].as_s.should eq("sig-z")
    end
  end

  describe "#build_chunk" do
    it "turns an OpenRouter streaming delta into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "model": "openai/gpt-4o",
        "choices": [{"delta": {"content": "Hel"}}]
      }
      JSON
      provider = configured_openrouter
      chunk = provider.build_chunk(data)
      chunk.should be_a(CrystalLLM::Chunk)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("openai/gpt-4o")
      chunk.content.should eq("Hel")
    end
  end

  describe "#stream_url / #completion_url" do
    it "points streaming at the completion endpoint" do
      provider = configured_openrouter
      provider.completion_url.should eq("chat/completions")
      provider.stream_url.should eq("chat/completions")
    end
  end

  describe "#models_url / #parse_list_models_response" do
    it "parses the rich OpenRouter model record" do
      body = <<-JSON
      {
        "data": [
          {
            "id": "anthropic/claude-3.5-sonnet",
            "name": "Claude 3.5 Sonnet",
            "created": 1718841600,
            "context_length": 200000,
            "architecture": {
              "input_modalities": ["text", "image"],
              "output_modalities": ["text"]
            },
            "pricing": {
              "prompt": "0.000003",
              "completion": "0.000015"
            },
            "top_provider": {"max_completion_tokens": 8192},
            "supported_parameters": ["tools", "tool_choice", "response_format"]
          }
        ]
      }
      JSON
      provider = configured_openrouter
      models = provider.parse_list_models_response(
        build_response(200, body), "openrouter", CrystalLLM::Providers::OpenRouter.capabilities
      )

      models.size.should eq(1)
      model = models.first
      model.id.should eq("anthropic/claude-3.5-sonnet")
      model.name.should eq("Claude 3.5 Sonnet")
      model.provider.should eq("openrouter")
      model.family.should eq("anthropic")
      model.context_window.should eq(200000)
      model.max_output_tokens.should eq(8192)
      model.modalities.input.should contain("image")
      model.capabilities.should contain("streaming")
      model.capabilities.should contain("function_calling")
      model.capabilities.should contain("structured_output")
      model.pricing.text_tokens.input.should eq(3.0)
      model.pricing.text_tokens.output.should eq(15.0)
    end
  end

  # supported_parameters_to_capabilities is a private models.cr helper (mirroring
  # ruby_llm's openrouter/models.rb); it is exercised through the public
  # parse_list_models_response surface rather than called directly.
  describe "supported_parameters -> capabilities (via #parse_list_models_response)" do
    it "maps supported_parameters to capability strings" do
      body = <<-JSON
      {
        "data": [
          {
            "id": "x/y",
            "name": "Y",
            "supported_parameters": ["tools", "response_format", "batch"]
          }
        ]
      }
      JSON
      model = configured_openrouter.parse_list_models_response(
        build_response(200, body), "openrouter", CrystalLLM::Providers::OpenRouter.capabilities
      ).first
      model.capabilities.should contain("streaming")
      model.capabilities.should contain("function_calling")
      model.capabilities.should contain("structured_output")
      model.capabilities.should contain("batch")
    end

    it "yields no capabilities when supported_parameters is absent (nil -> [])" do
      body = %({"data": [{"id": "x/y", "name": "Y"}]})
      model = configured_openrouter.parse_list_models_response(
        build_response(200, body), "openrouter", CrystalLLM::Providers::OpenRouter.capabilities
      ).first
      model.capabilities.should be_empty
    end
  end

  describe "#parse_error" do
    it "appends the nested provider message from error.metadata.raw" do
      body = File.read(File.join(__DIR__, "..", "fixtures", "cassettes", "openrouter", "error_403.json"))
      message = configured_openrouter.parse_error(build_response(403, body))
      message.should eq(
        "Provider returned error - Your credit balance is too low to access the Anthropic API."
      )
    end

    it "returns just the outer message when metadata.raw is absent" do
      body = %({"error": {"message": "Rate limited", "code": 429}})
      configured_openrouter.parse_error(build_response(429, body)).should eq("Rate limited")
    end

    it "returns the outer message when metadata.raw has no inner error message" do
      body = %({"error": {"message": "Bad gateway", "metadata": {"raw": "{\\"foo\\":\\"bar\\"}"}}})
      configured_openrouter.parse_error(build_response(502, body)).should eq("Bad gateway")
    end
  end
end
