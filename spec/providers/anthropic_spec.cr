require "../spec_helper"
require "../../src/crystal_llm/providers/anthropic"
require "../../src/crystal_llm/stream_accumulator"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_anthropic : CrystalLLM::Providers::Anthropic
  config = CrystalLLM::Configuration.new
  config.anthropic_api_key = "test"
  CrystalLLM::Providers::Anthropic.new(config)
end

private def claude_model : CrystalLLM::Model::Info
  # Mirrors claude-opus-4-5's real registry shape: both `effort` and
  # `budget_tokens` reasoning options (ruby_llm 3f27b864 adaptive thinking).
  CrystalLLM::Model::Info.build(
    id: "claude-3-5-sonnet-20241022",
    name: "Claude 3.5 Sonnet",
    provider: "anthropic",
    max_output_tokens: 8192,
    reasoning_options: [
      {"type" => JSON::Any.new("effort"), "values" => JSON::Any.new(["low", "medium", "high"].map { |v| JSON::Any.new(v) })},
      {"type" => JSON::Any.new("budget_tokens"), "min" => JSON::Any.new(1024)},
    ] of Hash(String, JSON::Any)
  )
end

# A model whose registry entry advertises only the given reasoning-option
# `types` (e.g. "budget_tokens", "effort") — used to exercise the
# unsupported-combination ArgumentError paths.
private def claude_model_with_reasoning(*types : String) : CrystalLLM::Model::Info
  options = [] of Hash(String, JSON::Any)
  types.each { |type| options << ({"type" => JSON::Any.new(type)} of String => JSON::Any) }

  CrystalLLM::Model::Info.build(
    id: "claude-reasoning-test",
    provider: "anthropic",
    max_output_tokens: 8192,
    reasoning_options: options
  )
end

describe CrystalLLM::Providers::Anthropic do
  describe "Configuration reopen" do
    it "adds anthropic_api_key/base to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("anthropic_api_key")
      CrystalLLM::Configuration.options.should contain("anthropic_api_base")
    end

    it "reads anthropic_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("anthropic_api_key").should be_false
      config.anthropic_api_key = "test"
      config.configured?("anthropic_api_key").should be_true
      config["anthropic_api_key"]?.should eq("test")
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("anthropic").should eq(CrystalLLM::Providers::Anthropic)
    end
  end

  describe "#api_base / #headers" do
    it "defaults api_base and builds x-api-key + version headers" do
      provider = configured_anthropic
      provider.api_base.should eq("https://api.anthropic.com")
      provider.headers["x-api-key"].should eq("test")
      provider.headers["anthropic-version"].should eq("2023-06-01")
    end

    it "honors a configured anthropic_api_base" do
      config = CrystalLLM::Configuration.new
      config.anthropic_api_key = "test"
      config.anthropic_api_base = "https://proxy.test"
      CrystalLLM::Providers::Anthropic.new(config).api_base.should eq("https://proxy.test")
    end
  end

  describe "#completion_url / #stream_url / #models_url" do
    it "uses the Anthropic Messages API paths" do
      provider = configured_anthropic
      provider.completion_url.should eq("v1/messages")
      provider.stream_url.should eq("v1/messages")
      provider.models_url.should eq("v1/models")
    end
  end

  describe "#render_payload" do
    it "produces the expected Anthropic messages JSON for [user \"hi\"] + a model id" do
      provider = configured_anthropic
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: claude_model,
        stream: false
      )

      payload["model"].as_s.should eq("claude-3-5-sonnet-20241022")
      payload["stream"].as_bool.should be_false
      payload["max_tokens"].as_i.should eq(8192)
      payload["temperature"].as_f.should eq(0.7)
      payload.has_key?("tools").should be_false
      payload.has_key?("system").should be_false

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msg = msgs[0].as_h
      msg["role"].as_s.should eq("user")
      blocks = msg["content"].as_a
      blocks.size.should eq(1)
      blocks[0].as_h["type"].as_s.should eq("text")
      blocks[0].as_h["text"].as_s.should eq("hi")
    end

    it "defaults max_tokens to 4096 when the model has none" do
      provider = configured_anthropic
      model = CrystalLLM::Model::Info.build(id: "claude-x", provider: "anthropic")
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: model,
        stream: false
      )
      payload["max_tokens"].as_i.should eq(4096)
      payload.has_key?("temperature").should be_false
    end

    it "extracts system messages into a top-level system array" do
      provider = configured_anthropic
      messages = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: "be terse"),
        CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi"),
      ]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false
      )

      system = payload["system"].as_a
      system.size.should eq(1)
      system[0].as_h["type"].as_s.should eq("text")
      system[0].as_h["text"].as_s.should eq("be terse")

      # system message is NOT in the messages array
      payload["messages"].as_a.size.should eq(1)
    end

    it "adds an output_config from a schema envelope (strict stripped)" do
      provider = configured_anthropic
      schema = JSON.parse(%({"name":"person","schema":{"type":"object","strict":true},"strict":true}))
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false,
        schema: schema
      )
      format = payload["output_config"].as_h["format"].as_h
      format["type"].as_s.should eq("json_schema")
      inner = format["schema"].as_h
      inner["type"].as_s.should eq("object")
      inner.has_key?("strict").should be_false
    end

    it "emits a {type:tool,name} tool_choice with disable_parallel from tool_prefs" do
      provider = configured_anthropic
      tool = CrystalLLM::DynamicTool.new("search", "Search", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: claude_model,
        stream: false,
        tool_prefs: {"choice" => "search", "calls" => "one"} of String => String?
      )
      tc = payload["tool_choice"].as_h
      tc["type"].as_s.should eq("tool")
      tc["name"].as_s.should eq("search")
      tc["disable_parallel_tool_use"].as_bool.should be_true
    end

    it "maps required→any and calls=many→disable_parallel false" do
      provider = configured_anthropic
      tool = CrystalLLM::DynamicTool.new("search", "Search", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: claude_model,
        stream: false,
        tool_prefs: {"choice" => "required", "calls" => "many"} of String => String?
      )
      tc = payload["tool_choice"].as_h
      tc["type"].as_s.should eq("any")
      tc["disable_parallel_tool_use"].as_bool.should be_false
    end

    it "omits tool_choice when tool_prefs is nil" do
      provider = configured_anthropic
      tool = CrystalLLM::DynamicTool.new("search", "Search", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: claude_model,
        stream: false
      )
      payload.has_key?("tool_choice").should be_false
    end

    it "renders tools with the flat input_schema shape" do
      provider = configured_anthropic
      tool = CrystalLLM::DynamicTool.new(
        "search", "Search the web",
        {"type"       => JSON::Any.new("object"),
         "properties" => JSON::Any.new({"q" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)} of String => JSON::Any)} of String => JSON::Any
      ) { |args| args["q"].as_s }

      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"search" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: claude_model,
        stream: false
      )
      tools = payload["tools"].as_a
      tools.size.should eq(1)
      defn = tools[0].as_h
      defn["name"].as_s.should eq("search")
      defn["description"].as_s.should eq("Search the web")
      defn["input_schema"].as_h["type"].as_s.should eq("object")
    end
  end

  # ruby_llm 3f27b864: `build_thinking_payload(thinking, model)` now consults the
  # model's registry `reasoning_options` to decide between legacy budget-based
  # thinking (`{thinking:{type:"enabled",budget_tokens:}}`) and adaptive
  # effort-based thinking (`{thinking:{type:"adaptive"},output_config:{effort:}}`),
  # raising ArgumentError when the model doesn't support the requested shape.
  describe "adaptive thinking payload (ruby_llm 3f27b864)" do
    it "emits {type:enabled, budget_tokens} for a budget on a model with the budget_tokens option" do
      provider = configured_anthropic
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false,
        thinking: CrystalLLM::Thinking::Config.new(budget: 2048)
      )

      thinking = payload["thinking"].as_h
      thinking["type"].as_s.should eq("enabled")
      thinking["budget_tokens"].as_i.should eq(2048)
      payload.has_key?("output_config").should be_false
    end

    it "emits {type:adaptive} + output_config:{effort} for an effort on a model with the effort option" do
      provider = configured_anthropic
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false,
        thinking: CrystalLLM::Thinking::Config.new(effort: "medium")
      )

      thinking = payload["thinking"].as_h
      thinking["type"].as_s.should eq("adaptive")
      payload["output_config"].as_h["effort"].as_s.should eq("medium")
    end

    it "merges adaptive-thinking output_config with the schema-driven output_config rather than overwriting it" do
      provider = configured_anthropic
      schema = JSON.parse(%({"name":"person","schema":{"type":"object","strict":true},"strict":true}))
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false,
        schema: schema,
        thinking: CrystalLLM::Thinking::Config.new(effort: "high")
      )

      output_config = payload["output_config"].as_h
      output_config["effort"].as_s.should eq("high")
      output_config["format"].as_h["type"].as_s.should eq("json_schema")
    end

    it "disables thinking for effort:none (no thinking or output_config key emitted)" do
      provider = configured_anthropic
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false,
        thinking: CrystalLLM::Thinking::Config.new(effort: "none")
      )

      payload.has_key?("thinking").should be_false
      payload.has_key?("output_config").should be_false
    end

    it "raises ArgumentError naming the model when a budget is given for an effort-only model" do
      provider = configured_anthropic
      model = claude_model_with_reasoning("effort")

      expect_raises(ArgumentError, /claude-reasoning-test/) do
        provider.render_payload(
          [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
          tools: {} of String => CrystalLLM::Tool,
          temperature: nil,
          model: model,
          stream: false,
          thinking: CrystalLLM::Thinking::Config.new(budget: 1024)
        )
      end
    end

    it "raises ArgumentError naming the model when an effort is given for a budget-only model" do
      provider = configured_anthropic
      model = claude_model_with_reasoning("budget_tokens")

      expect_raises(ArgumentError, /claude-reasoning-test/) do
        provider.render_payload(
          [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
          tools: {} of String => CrystalLLM::Tool,
          temperature: nil,
          model: model,
          stream: false,
          thinking: CrystalLLM::Thinking::Config.new(effort: "medium")
        )
      end
    end

    it "raises ArgumentError when adaptive thinking is enabled without an effort" do
      provider = configured_anthropic

      expect_raises(ArgumentError, "Anthropic adaptive thinking requires an effort") do
        provider.render_payload(
          [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
          tools: {} of String => CrystalLLM::Tool,
          temperature: nil,
          model: claude_model,
          stream: false,
          thinking: CrystalLLM::Thinking::Config.new(effort: "")
        )
      end
    end
  end

  describe "#parse_completion_response" do
    it "turns an Anthropic completion JSON into a Message with content + tokens" do
      body = <<-JSON
      {
        "id": "msg_1",
        "model": "claude-3-5-sonnet-20241022",
        "role": "assistant",
        "content": [
          {"type": "text", "text": "Hello there!"}
        ],
        "usage": {"input_tokens": 12, "output_tokens": 5}
      }
      JSON
      provider = configured_anthropic
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello there!")
      message.model_id.should eq("claude-3-5-sonnet-20241022")
      message.input_tokens.should eq(12)
      message.output_tokens.should eq(5)
      message.tool_call?.should be_false
    end

    it "parses tool_use blocks into tool calls" do
      body = <<-JSON
      {
        "id": "msg_2",
        "model": "claude-3-5-sonnet-20241022",
        "content": [
          {"type": "text", "text": "Let me check."},
          {"type": "tool_use", "id": "toolu_1", "name": "get_weather",
           "input": {"city": "Paris"}}
        ],
        "usage": {"input_tokens": 10, "output_tokens": 8}
      }
      JSON
      provider = configured_anthropic
      message = provider.parse_completion_response(build_response(200, body))

      message.tool_call?.should be_true
      calls = message.tool_calls
      calls.should_not be_nil
      raise "no tool calls" unless calls
      calls.size.should eq(1)
      call = calls["toolu_1"]
      call.name.should eq("get_weather")
      call.arguments["city"].as_s.should eq("Paris")
    end

    it "reads cached + cache-creation token usage" do
      body = <<-JSON
      {
        "model": "claude-3-5-sonnet-20241022",
        "content": [{"type": "text", "text": "ok"}],
        "usage": {
          "input_tokens": 5, "output_tokens": 2,
          "cache_read_input_tokens": 100,
          "cache_creation": {"ephemeral_5m_input_tokens": 30, "ephemeral_1h_input_tokens": 20}
        }
      }
      JSON
      provider = configured_anthropic
      message = provider.parse_completion_response(build_response(200, body))
      message.cached_tokens.should eq(100)
      message.cache_creation_tokens.should eq(50)
    end

    it "raises on an error body" do
      body = %({"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
      provider = configured_anthropic
      expect_raises(CrystalLLM::Error, "invalid x-api-key") do
        provider.parse_completion_response(build_response(401, body))
      end
    end

    it "attaches thinking text + signature from a thinking content block" do
      body = <<-JSON
      {
        "model": "claude-3-5-sonnet-20241022",
        "content": [
          {"type": "thinking", "thinking": "Let me reason about this.", "signature": "sig-abc"},
          {"type": "text", "text": "The answer is 42."}
        ],
        "usage": {"input_tokens": 10, "output_tokens": 8}
      }
      JSON
      provider = configured_anthropic
      message = provider.parse_completion_response(build_response(200, body))

      message.content.should eq("The answer is 42.")
      thinking = message.thinking.should_not be_nil
      thinking.text.should eq("Let me reason about this.")
      thinking.signature.should eq("sig-abc")
    end

    it "reads a redacted_thinking signature when only a redacted block is present" do
      body = <<-JSON
      {
        "model": "claude-3-5-sonnet-20241022",
        "content": [
          {"type": "redacted_thinking", "data": "redacted-sig"},
          {"type": "text", "text": "ok"}
        ],
        "usage": {"input_tokens": 3, "output_tokens": 2}
      }
      JSON
      provider = configured_anthropic
      message = provider.parse_completion_response(build_response(200, body))
      thinking = message.thinking.should_not be_nil
      thinking.text.should be_nil
      thinking.signature.should eq("redacted-sig")
    end

    it "leaves thinking nil when no thinking block is present" do
      body = <<-JSON
      {
        "model": "claude-3-5-sonnet-20241022",
        "content": [{"type": "text", "text": "hi"}],
        "usage": {"input_tokens": 1, "output_tokens": 1}
      }
      JSON
      provider = configured_anthropic
      provider.parse_completion_response(build_response(200, body)).thinking.should be_nil
    end
  end

  describe "outbound thinking blocks (multi-turn extended thinking)" do
    it "prepends a thinking block to an assistant message when thinking is enabled" do
      provider = configured_anthropic
      thinking_cfg = CrystalLLM::Thinking::Config.new(budget: 1024)
      assistant = CrystalLLM::Message.new(
        role: CrystalLLM::Role::Assistant, content: "the answer",
        thinking: CrystalLLM::Thinking.new(text: "reasoning here", signature: "sig-1")
      )
      messages = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "q"),
        assistant,
      ]

      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false,
        thinking: thinking_cfg
      )

      assistant_msg = payload["messages"].as_a[1].as_h
      blocks = assistant_msg["content"].as_a
      blocks[0].as_h["type"].as_s.should eq("thinking")
      blocks[0].as_h["thinking"].as_s.should eq("reasoning here")
      blocks[0].as_h["signature"].as_s.should eq("sig-1")
      # the actual content follows the thinking block
      blocks[1].as_h["type"].as_s.should eq("text")
      blocks[1].as_h["text"].as_s.should eq("the answer")
    end

    it "emits a redacted_thinking block for a signature-only assistant message" do
      provider = configured_anthropic
      thinking_cfg = CrystalLLM::Thinking::Config.new(budget: 512)
      assistant = CrystalLLM::Message.new(
        role: CrystalLLM::Role::Assistant, content: "x",
        thinking: CrystalLLM::Thinking.new(signature: "redacted-1")
      )

      payload = provider.render_payload(
        [assistant],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false,
        thinking: thinking_cfg
      )

      blocks = payload["messages"].as_a[0].as_h["content"].as_a
      blocks[0].as_h["type"].as_s.should eq("redacted_thinking")
      blocks[0].as_h["data"].as_s.should eq("redacted-1")
    end

    it "does NOT prepend a thinking block when thinking is disabled" do
      provider = configured_anthropic
      assistant = CrystalLLM::Message.new(
        role: CrystalLLM::Role::Assistant, content: "the answer",
        thinking: CrystalLLM::Thinking.new(text: "reasoning here", signature: "sig-1")
      )

      payload = provider.render_payload(
        [assistant],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false
      )

      blocks = payload["messages"].as_a[0].as_h["content"].as_a
      blocks[0].as_h["type"].as_s.should eq("text")
    end
  end

  describe "#build_chunk" do
    it "turns an Anthropic text_delta event into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "text_delta", "text": "Hel"}
      }
      JSON
      provider = configured_anthropic
      chunk = provider.build_chunk(data)
      chunk.should be_a(CrystalLLM::Chunk)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.content.should eq("Hel")
    end

    it "reads model id + usage from a message_start event" do
      data = JSON.parse(<<-JSON)
      {
        "type": "message_start",
        "message": {
          "model": "claude-3-5-sonnet-20241022",
          "usage": {"input_tokens": 3, "output_tokens": 1}
        }
      }
      JSON
      provider = configured_anthropic
      chunk = provider.build_chunk(data)
      chunk.model_id.should eq("claude-3-5-sonnet-20241022")
      chunk.input_tokens.should eq(3)
    end

    it "attaches thinking text from a thinking_delta event" do
      data = JSON.parse(%({"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"step "}}))
      chunk = configured_anthropic.build_chunk(data)
      chunk.thinking.should_not be_nil
      chunk.thinking.try(&.text).should eq("step ")
      chunk.content.should be_nil
    end

    it "attaches a signature from a signature_delta event" do
      data = JSON.parse(%({"type":"content_block_delta","delta":{"type":"signature_delta","signature":"sig-x"}}))
      chunk = configured_anthropic.build_chunk(data)
      chunk.thinking.should_not be_nil
      chunk.thinking.try(&.signature).should eq("sig-x")
    end

    it "accumulates streamed thinking_delta + signature_delta into the final Message" do
      provider = configured_anthropic
      accumulator = CrystalLLM::StreamAccumulator.new
      events = [
        %({"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"I will "}}),
        %({"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"reason."}}),
        %({"type":"content_block_delta","delta":{"type":"signature_delta","signature":"sig-final"}}),
        %({"type":"content_block_delta","delta":{"type":"text_delta","text":"Done."}}),
      ]
      events.each { |e| accumulator.add(provider.build_chunk(JSON.parse(e))) }

      message = accumulator.to_message(nil)
      message.content.should eq("Done.")
      thinking = message.thinking.should_not be_nil
      thinking.text.should eq("I will reason.")
      thinking.signature.should eq("sig-final")
    end

    # REGRESSION (ruby_llm ff19c933): Anthropic streams parallel tool calls as
    # interleaved content_block_start/content_block_delta events distinguished
    # only by `index`. extract_tool_calls must key both the tool-call start and
    # its argument-fragment deltas by the stringified index, so the
    # StreamAccumulator can route interleaved fragments to the right call
    # instead of clobbering `@latest_tool_call_id`.
    it "keeps interleaved parallel tool calls separate via the content-block index" do
      provider = configured_anthropic
      accumulator = CrystalLLM::StreamAccumulator.new
      events = [
        %({"type":"content_block_start","index":0,"content_block":) +
        %({"type":"tool_use","id":"tc_a","name":"alpha","input":{}}}),
        %({"type":"content_block_start","index":1,"content_block":) +
        %({"type":"tool_use","id":"tc_b","name":"beta","input":{}}}),
        %({"type":"content_block_delta","index":0,) +
        %("delta":{"type":"input_json_delta","partial_json":"{\\"x\\":"}}),
        %({"type":"content_block_delta","index":1,) +
        %("delta":{"type":"input_json_delta","partial_json":"{\\"y\\":1}"}}),
        %({"type":"content_block_delta","index":0,) +
        %("delta":{"type":"input_json_delta","partial_json":"1}"}}),
      ]
      events.each { |e| accumulator.add(provider.build_chunk(JSON.parse(e))) }

      message = accumulator.to_message(nil)
      tool_calls = message.tool_calls.should_not be_nil
      tool_calls["tc_a"].arguments["x"].as_i.should eq(1)
      tool_calls["tc_b"].arguments["y"].as_i.should eq(1)
    end
  end

  describe "#parse_list_models_response" do
    it "parses Anthropic's /v1/models data array" do
      body = <<-JSON
      {
        "data": [
          {"type": "model", "id": "claude-3-5-sonnet-20241022",
           "display_name": "Claude 3.5 Sonnet", "created_at": "2024-10-22T00:00:00Z"}
        ]
      }
      JSON
      provider = configured_anthropic
      models = provider.parse_list_models_response(
        build_response(200, body), "anthropic", CrystalLLM::Providers::Anthropic.capabilities
      )
      models.size.should eq(1)
      models[0].id.should eq("claude-3-5-sonnet-20241022")
      models[0].name.should eq("Claude 3.5 Sonnet")
      models[0].provider.should eq("anthropic")
    end
  end

  describe "Capabilities" do
    it "reports tool-choice + parallel-control support" do
      caps = CrystalLLM::Providers::Anthropic::Capabilities
      caps.supports_tool_choice?("claude-3-5-sonnet-20241022").should be_true
      caps.supports_tool_parallel_control?("claude-3-5-sonnet-20241022").should be_true
    end
  end

  describe "Tools.build_tool_choice" do
    it "maps choice keywords to Anthropic tool_choice types" do
      auto = CrystalLLM::Providers::Anthropic::Tools.build_tool_choice("auto", nil).as_h
      auto["type"].as_s.should eq("auto")

      required = CrystalLLM::Providers::Anthropic::Tools.build_tool_choice("required", nil).as_h
      required["type"].as_s.should eq("any")

      named = CrystalLLM::Providers::Anthropic::Tools.build_tool_choice("get_weather", "one").as_h
      named["type"].as_s.should eq("tool")
      named["name"].as_s.should eq("get_weather")
      named["disable_parallel_tool_use"].as_bool.should be_true
    end
  end
end
