require "../spec_helper"
require "../../src/crystal_llm/provider_completion"
require "../../src/crystal_llm/providers/bedrock"
require "../support/stub_connection"
require "base64"
require "digest/crc32"

# Builds one AWS `application/vnd.amazon.eventstream` binary frame around *payload*
# (already-serialized JSON bytes), with valid prelude + message CRC32s and a single
# minimal `:event-type` / `:message-type` header pair (headers are not parsed by the
# decoder, but a realistic non-empty header section exercises the offset math).
# When *corrupt_crc* is true the trailing message CRC is flipped so the decoder's
# integrity check can be asserted.
private def build_eventstream_frame(payload : String, corrupt_crc : Bool = false) : Bytes
  # One header: name=":event-type" (string value "contentBlockDelta").
  headers = IO::Memory.new
  name = ":event-type"
  value = "contentBlockDelta"
  headers.write_byte(name.bytesize.to_u8)
  headers.write(name.to_slice)
  headers.write_byte(7_u8) # header value type 7 = string
  headers.write_bytes(value.bytesize.to_u16, IO::ByteFormat::BigEndian)
  headers.write(value.to_slice)
  headers_bytes = headers.to_slice

  payload_bytes = payload.to_slice
  total_len = 16_u32 + headers_bytes.size + payload_bytes.size

  prelude = IO::Memory.new
  prelude.write_bytes(total_len, IO::ByteFormat::BigEndian)
  prelude.write_bytes(headers_bytes.size.to_u32, IO::ByteFormat::BigEndian)
  prelude_first8 = prelude.to_slice
  prelude.write_bytes(Digest::CRC32.checksum(prelude_first8), IO::ByteFormat::BigEndian)
  prelude_bytes = prelude.to_slice

  frame = IO::Memory.new
  frame.write(prelude_bytes)
  frame.write(headers_bytes)
  frame.write(payload_bytes)
  message_crc = Digest::CRC32.checksum(frame.to_slice)
  message_crc = message_crc ^ 0xFFFFFFFF_u32 if corrupt_crc
  frame.write_bytes(message_crc, IO::ByteFormat::BigEndian)
  frame.to_slice
end

# A frame whose inner payload is the model SSE-style event JSON wrapped in the
# base64 `{"bytes": ...}` envelope Bedrock uses.
private def build_bytes_frame(event_json : String, corrupt_crc : Bool = false) : Bytes
  outer = {"bytes" => Base64.strict_encode(event_json)}.to_json
  build_eventstream_frame(outer, corrupt_crc)
end

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

private def configured_bedrock : CrystalLLM::Providers::Bedrock
  config = CrystalLLM::Configuration.new
  config.bedrock_api_key = "test"
  config.bedrock_secret_key = "test"
  config.bedrock_region = "us-east-1"
  CrystalLLM::Providers::Bedrock.new(config)
end

private def claude_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(
    id: "anthropic.claude-3-sonnet-20240229-v1:0",
    name: "Claude 3 Sonnet",
    provider: "bedrock"
  )
end

describe CrystalLLM::Providers::Bedrock do
  describe "Configuration reopen" do
    it "adds the bedrock options to Configuration.options" do
      CrystalLLM::Configuration.options.should contain("bedrock_api_key")
      CrystalLLM::Configuration.options.should contain("bedrock_secret_key")
      CrystalLLM::Configuration.options.should contain("bedrock_region")
      CrystalLLM::Configuration.options.should contain("bedrock_session_token")
    end

    it "reads bedrock_api_key via []? (configured?)" do
      config = CrystalLLM::Configuration.new
      config.configured?("bedrock_api_key").should be_false
      config.bedrock_api_key = "AKIA"
      config.configured?("bedrock_api_key").should be_true
      config["bedrock_api_key"]?.should eq("AKIA")
    end

    it "exposes the configuration_requirements" do
      CrystalLLM::Providers::Bedrock.configuration_requirements.should eq(
        ["bedrock_api_key", "bedrock_secret_key", "bedrock_region"]
      )
    end
  end

  describe "registry" do
    it "resolves the provider by name" do
      CrystalLLM::Provider.resolve("bedrock").should eq(CrystalLLM::Providers::Bedrock)
    end
  end

  describe "#api_base / #headers" do
    it "builds the region-scoped runtime host" do
      configured_bedrock.api_base.should eq("https://bedrock-runtime.us-east-1.amazonaws.com")
    end

    it "returns a best-effort content-type header (auth deferred)" do
      configured_bedrock.headers["Content-Type"].should eq("application/json")
    end
  end

  describe "#completion_url / #stream_url" do
    it "embeds the model id once render_payload set it" do
      provider = configured_bedrock
      provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false
      )
      provider.completion_url.should eq("/model/anthropic.claude-3-sonnet-20240229-v1:0/converse")
      provider.stream_url.should eq("/model/anthropic.claude-3-sonnet-20240229-v1:0/converse-stream")
    end
  end

  describe "#sign_headers (AWS SigV4)" do
    it "returns an AWS4-HMAC-SHA256 Authorization + X-Amz-Date for a POST" do
      headers = configured_bedrock.sign_headers("POST", "/model/m/converse", %({"a":1}))

      headers["Authorization"].should start_with("AWS4-HMAC-SHA256 ")
      headers["Authorization"].should contain("Credential=test/")
      headers["Authorization"].should contain("/us-east-1/bedrock/aws4_request")
      headers["Authorization"].should contain("SignedHeaders=")
      headers["Authorization"].should contain("Signature=")
      # x-amz-date is in the basic ISO8601 SigV4 form (YYYYMMDDTHHMMSSZ).
      headers["X-Amz-Date"].should match(/\A\d{8}T\d{6}Z\z/)
      headers["X-Amz-Content-Sha256"].should match(/\A[0-9a-f]{64}\z/)
      headers["Content-Type"].should eq("application/json")
      headers.has_key?("X-Amz-Security-Token").should be_false
    end

    it "signs the host so it appears in SignedHeaders" do
      headers = configured_bedrock.sign_headers("POST", "/model/m/converse", "{}")
      headers["Authorization"].should contain("SignedHeaders=host;")
    end

    it "changes the signature when the body changes" do
      provider = configured_bedrock
      one = provider.sign_headers("POST", "/model/m/converse", %({"a":1}))
      two = provider.sign_headers("POST", "/model/m/converse", %({"a":2}))

      one["Authorization"].should_not eq(two["Authorization"])
      one["X-Amz-Content-Sha256"].should_not eq(two["X-Amz-Content-Sha256"])
    end

    it "includes a session token (in the header and the signed headers) when configured" do
      config = CrystalLLM::Configuration.new
      config.bedrock_api_key = "test"
      config.bedrock_secret_key = "test"
      config.bedrock_region = "us-east-1"
      config.bedrock_session_token = "SESSION-TOKEN"
      provider = CrystalLLM::Providers::Bedrock.new(config)

      headers = provider.sign_headers("POST", "/model/m/converse", "{}")
      headers["X-Amz-Security-Token"].should eq("SESSION-TOKEN")
      headers["Authorization"].should contain("x-amz-security-token")
    end

    it "signs a GET against the control-plane models host" do
      provider = configured_bedrock
      provider.models_url.should eq("https://bedrock.us-east-1.amazonaws.com/foundation-models")

      headers = provider.sign_headers("GET", provider.models_url, "")
      headers["Authorization"].should start_with("AWS4-HMAC-SHA256 ")
      headers["Authorization"].should contain("/bedrock/aws4_request")
    end

    it "threads the signed headers into the POST request pipeline (no network)" do
      provider = configured_bedrock
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(%({"output":{"message":{"role":"assistant","content":[{"text":"hi"}]}}}))
      provider.connection = stub

      provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false
      )
      provider.sync_response(%({"messages":[]}))

      sent = stub.request_headers.last
      sent["Authorization"].should start_with("AWS4-HMAC-SHA256 ")
      sent["X-Amz-Date"].should match(/\A\d{8}T\d{6}Z\z/)
      sent.has_key?("X-Amz-Content-Sha256").should be_true
    end
  end

  describe "#render_payload" do
    it "produces the Bedrock Converse JSON for a simple user message" do
      provider = configured_bedrock
      messages = [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")]
      payload = provider.render_payload(
        messages,
        tools: {} of String => CrystalLLM::Tool,
        temperature: 0.7,
        model: claude_model,
        stream: false
      )

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      content = msgs[0].as_h["content"].as_a
      content.size.should eq(1)
      content[0].as_h["text"].as_s.should eq("hi")

      payload["inferenceConfig"].as_h["temperature"].as_f.should eq(0.7)
      payload.has_key?("toolConfig").should be_false
      payload.has_key?("system").should be_false
    end

    it "omits temperature from inferenceConfig when nil" do
      provider = configured_bedrock
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false
      )
      payload["inferenceConfig"].as_h.has_key?("temperature").should be_false
    end

    it "renders system messages into a system block" do
      provider = configured_bedrock
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
      system_blocks = payload["system"].as_a
      system_blocks.size.should eq(1)
      system_blocks[0].as_h["text"].as_s.should eq("be terse")
      # system messages are partitioned out of the messages array
      payload["messages"].as_a.size.should eq(1)
    end

    it "renders a toolConfig from a tool with no top-level tools mirror" do
      provider = configured_bedrock
      tool = CrystalLLM::DynamicTool.new(
        "get_weather", "Look up the weather",
        {"type"       => JSON::Any.new("object"),
         "properties" => JSON::Any.new({"city" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)} of String => JSON::Any)} of String => JSON::Any
      ) { |args| args["city"].as_s }
      tools = {"get_weather" => tool.as(CrystalLLM::Tool)}

      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "weather?")],
        tools: tools,
        temperature: nil,
        model: claude_model,
        stream: false
      )

      tool_config = payload["toolConfig"].as_h
      specs = tool_config["tools"].as_a
      specs.size.should eq(1)
      tool_spec = specs[0].as_h["toolSpec"].as_h
      tool_spec["name"].as_s.should eq("get_weather")
      tool_spec["description"].as_s.should eq("Look up the weather")
      tool_spec["inputSchema"].as_h["json"].as_h["type"].as_s.should eq("object")
      # No redundant top-level `tools` mirror leaks onto the Converse request — real
      # tools live under toolConfig.tools (the mirror existed in ruby_llm only to be
      # deleted before signing; that delete step collapsed away in the port).
      payload.has_key?("tools").should be_false
    end

    it "emits toolConfig.toolChoice from tool_prefs (named tool)" do
      provider = configured_bedrock
      tool = CrystalLLM::DynamicTool.new("get_weather", "weather", {} of String => JSON::Any) { |_| "" }
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {"get_weather" => tool.as(CrystalLLM::Tool)},
        temperature: nil,
        model: claude_model,
        stream: false,
        tool_prefs: {"choice" => "get_weather", "calls" => nil} of String => String?
      )
      tc = payload["toolConfig"].as_h["toolChoice"].as_h
      tc["tool"].as_h["name"].as_s.should eq("get_weather")
    end

    it "maps required→{any:{}} and omits toolChoice when no choice" do
      provider = configured_bedrock
      tool = CrystalLLM::DynamicTool.new("get_weather", "weather", {} of String => JSON::Any) { |_| "" }
      tools = {"get_weather" => tool.as(CrystalLLM::Tool)}
      required = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: tools, temperature: nil, model: claude_model, stream: false,
        tool_prefs: {"choice" => "required", "calls" => nil} of String => String?
      )
      required["toolConfig"].as_h["toolChoice"].as_h.has_key?("any").should be_true

      none = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: tools, temperature: nil, model: claude_model, stream: false
      )
      none["toolConfig"].as_h.has_key?("toolChoice").should be_false
    end

    it "builds an outputConfig from a schema envelope" do
      provider = configured_bedrock
      schema = JSON.parse(%({"name":"person","schema":{"type":"object","strict":true}}))
      payload = provider.render_payload(
        [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
        tools: {} of String => CrystalLLM::Tool,
        temperature: nil,
        model: claude_model,
        stream: false,
        schema: schema
      )
      structure = payload["outputConfig"].as_h["textFormat"].as_h["structure"].as_h["jsonSchema"].as_h
      structure["name"].as_s.should eq("person")
      # the inner schema is JSON-stringified and has `strict` stripped
      structure["schema"].as_s.includes?("strict").should be_false
      structure["schema"].as_s.includes?("object").should be_true
    end
  end

  describe "#parse_completion_response" do
    it "turns a Bedrock Converse completion into a Message with content + tokens" do
      body = <<-JSON
      {
        "modelId": "anthropic.claude-3-sonnet-20240229-v1:0",
        "output": {
          "message": {
            "role": "assistant",
            "content": [{"text": "Hello there!"}]
          }
        },
        "usage": {"inputTokens": 12, "outputTokens": 5}
      }
      JSON
      provider = configured_bedrock
      message = provider.parse_completion_response(build_response(200, body))

      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should eq("Hello there!")
      message.model_id.should eq("anthropic.claude-3-sonnet-20240229-v1:0")
      message.input_tokens.should eq(12)
      message.output_tokens.should eq(5)
      message.tool_call?.should be_false
    end

    it "subtracts cache tokens from inputTokens" do
      body = <<-JSON
      {
        "output": {"message": {"role": "assistant", "content": [{"text": "hi"}]}},
        "usage": {"inputTokens": 100, "outputTokens": 5, "cacheReadInputTokens": 30, "cacheWriteInputTokens": 10}
      }
      JSON
      provider = configured_bedrock
      message = provider.parse_completion_response(build_response(200, body))
      message.input_tokens.should eq(60)
      message.cached_tokens.should eq(30)
      message.cache_creation_tokens.should eq(10)
    end

    it "parses a toolUse block into tool calls" do
      body = <<-JSON
      {
        "output": {
          "message": {
            "role": "assistant",
            "content": [
              {"toolUse": {"toolUseId": "tu_1", "name": "get_weather", "input": {"city": "Paris"}}}
            ]
          }
        },
        "usage": {"inputTokens": 10, "outputTokens": 8}
      }
      JSON
      provider = configured_bedrock
      message = provider.parse_completion_response(build_response(200, body))

      message.tool_call?.should be_true
      calls = message.tool_calls
      raise "no tool calls" unless calls
      calls.size.should eq(1)
      call = calls["tu_1"]
      call.name.should eq("get_weather")
      call.arguments["city"].as_s.should eq("Paris")
    end

    it "raises on an empty body" do
      provider = configured_bedrock
      expect_raises(CrystalLLM::Error) do
        provider.parse_completion_response(build_response(200, ""))
      end
    end
  end

  describe "#build_chunk" do
    it "turns a contentBlockDelta text event into a Chunk" do
      data = JSON.parse(<<-JSON)
      {
        "modelId": "anthropic.claude-3-sonnet-20240229-v1:0",
        "contentBlockDelta": {"delta": {"text": "Hel"}}
      }
      JSON
      provider = configured_bedrock
      chunk = provider.build_chunk(data)
      chunk.should be_a(CrystalLLM::Chunk)
      chunk.role.should eq(CrystalLLM::Role::Assistant)
      chunk.model_id.should eq("anthropic.claude-3-sonnet-20240229-v1:0")
      chunk.content.should eq("Hel")
    end

    it "carries metadata usage tokens on the final chunk" do
      data = JSON.parse(<<-JSON)
      {
        "metadata": {"usage": {"inputTokens": 3, "outputTokens": 4}}
      }
      JSON
      provider = configured_bedrock
      chunk = provider.build_chunk(data)
      chunk.input_tokens.should eq(3)
      chunk.output_tokens.should eq(4)
    end

    it "extracts a toolUse start delta" do
      data = JSON.parse(<<-JSON)
      {
        "contentBlockStart": {"start": {"toolUse": {"toolUseId": "tu_9", "name": "search", "input": {}}}}
      }
      JSON
      provider = configured_bedrock
      chunk = provider.build_chunk(data)
      calls = chunk.tool_calls
      raise "no tool calls" unless calls
      calls["tu_9"].name.should eq("search")
    end

    # REGRESSION (BUG 1): Bedrock toolUse `input` arrives as a raw partial-JSON
    # String fragment. build_chunk must read it as_s? (not as_h?) and carry it raw;
    # the accumulator then concatenates the fragments and parses ONCE. Before the
    # fix, as_h? on a String fragment returned nil and the args were dropped.
    it "reconstructs streamed toolUse argument fragments through the accumulator" do
      provider = configured_bedrock
      accumulator = CrystalLLM::StreamAccumulator.new

      start = JSON.parse(%({"contentBlockStart":{"start":{"toolUse":{"toolUseId":"tu_1","name":"weather"}}}}))
      accumulator.add(provider.build_chunk(start))

      [%({"city": "Par), %(is"})].each do |frag|
        event = JSON.parse(%({"contentBlockDelta":{"delta":{"toolUse":{"input":#{frag.to_json}}}}}))
        accumulator.add(provider.build_chunk(event))
      end

      calls = accumulator.to_message(nil).tool_calls
      raise "no tool calls" unless calls
      calls["tu_1"].name.should eq("weather")
      calls["tu_1"].arguments["city"].as_s.should eq("Paris")
    end
  end

  describe "#parse_list_models_response" do
    it "parses modelSummaries into Model::Info records" do
      body = <<-JSON
      {
        "modelSummaries": [
          {
            "modelId": "anthropic.claude-3-sonnet-20240229-v1:0",
            "modelName": "Claude 3 Sonnet",
            "providerName": "Anthropic",
            "inputModalities": ["TEXT", "IMAGE"],
            "outputModalities": ["TEXT"],
            "responseStreamingSupported": true,
            "inferenceTypesSupported": ["ON_DEMAND"],
            "converse": {"maxTokensDefault": 4096}
          }
        ]
      }
      JSON
      provider = configured_bedrock
      models = provider.parse_list_models_response(
        build_response(200, body),
        "bedrock",
        CrystalLLM::Providers::Bedrock::Capabilities
      )
      models.size.should eq(1)
      info = models[0]
      info.id.should eq("anthropic.claude-3-sonnet-20240229-v1:0")
      info.name.should eq("Claude 3 Sonnet")
      info.family.should eq("anthropic")
      info.max_output_tokens.should eq(4096)
      info.capabilities.should contain("streaming")
      info.capabilities.should contain("function_calling")
      info.modalities.input.should contain("text")
      info.modalities.input.should contain("image")
    end

    it "applies a region prefix for inference-profile-only models" do
      body = <<-JSON
      {
        "modelSummaries": [
          {
            "modelId": "anthropic.claude-haiku-4-5-20251001-v1:0",
            "modelName": "Claude Haiku 4.5",
            "inferenceTypesSupported": ["INFERENCE_PROFILE"],
            "converse": {}
          }
        ]
      }
      JSON
      provider = configured_bedrock
      models = provider.parse_list_models_response(
        build_response(200, body),
        "bedrock",
        CrystalLLM::Providers::Bedrock::Capabilities
      )
      models[0].id.should eq("us.anthropic.claude-haiku-4-5-20251001-v1:0")
      # claude 4.5 supports structured output
      models[0].capabilities.should contain("structured_output")
    end
  end

  describe "Capabilities.reasoning_embedded?" do
    it "reads converse.reasoningSupported.embedded from model metadata" do
      model = CrystalLLM::Model::Info.build(
        id: "x",
        provider: "bedrock",
        metadata: {
          "converse" => JSON::Any.new({
            "reasoningSupported" => JSON::Any.new({"embedded" => JSON::Any.new(true)} of String => JSON::Any),
          } of String => JSON::Any),
        } of String => JSON::Any
      )
      CrystalLLM::Providers::Bedrock::Capabilities.reasoning_embedded?(model).should be_true

      plain = CrystalLLM::Model::Info.build(id: "y", provider: "bedrock")
      CrystalLLM::Providers::Bedrock::Capabilities.reasoning_embedded?(plain).should be_false
    end
  end

  describe "binary eventstream decode" do
    it "extracts the inner base64 `bytes` JSON event from a single frame" do
      event_json = %({"contentBlockDelta": {"delta": {"text": "Hel"}}})
      io = IO::Memory.new(build_bytes_frame(event_json))

      events = [] of JSON::Any
      configured_bedrock.decode_event_stream(io) { |event| events << event }

      events.size.should eq(1)
      events[0].dig("contentBlockDelta", "delta", "text").as_s.should eq("Hel")
    end

    it "decodes the frame and builds a Chunk end-to-end" do
      provider = configured_bedrock
      event_json = %({"modelId": "anthropic.claude-3-sonnet-20240229-v1:0", "contentBlockDelta": {"delta": {"text": "Hi"}}})
      io = IO::Memory.new(build_bytes_frame(event_json))

      chunks = [] of CrystalLLM::Chunk
      provider.decode_event_stream(io) do |event|
        chunks << provider.build_chunk(event)
      end

      chunks.size.should eq(1)
      chunks[0].content.should eq("Hi")
      chunks[0].model_id.should eq("anthropic.claude-3-sonnet-20240229-v1:0")
    end

    it "decodes multiple back-to-back frames off one stream" do
      io = IO::Memory.new
      io.write(build_bytes_frame(%({"contentBlockDelta": {"delta": {"text": "foo"}}})))
      io.write(build_bytes_frame(%({"contentBlockDelta": {"delta": {"text": "bar"}}})))
      io.write(build_bytes_frame(%({"metadata": {"usage": {"inputTokens": 5, "outputTokens": 7}}})))
      io.rewind

      provider = configured_bedrock
      accumulator = CrystalLLM::StreamAccumulator.new
      provider.decode_event_stream(io) { |event| accumulator.add(provider.build_chunk(event)) }

      message = accumulator.to_message(nil)
      message.content.should eq("foobar")
      message.input_tokens.should eq(5)
      message.output_tokens.should eq(7)
    end

    it "handles a frame whose outer payload IS the event (no `bytes` envelope)" do
      io = IO::Memory.new(build_eventstream_frame(%({"contentBlockDelta": {"delta": {"text": "raw"}}})))

      events = [] of JSON::Any
      configured_bedrock.decode_event_stream(io) { |event| events << event }

      events.size.should eq(1)
      events[0].dig("contentBlockDelta", "delta", "text").as_s.should eq("raw")
    end

    it "raises EventStreamError on a corrupt message CRC" do
      io = IO::Memory.new(build_bytes_frame(%({"contentBlockDelta": {"delta": {"text": "x"}}}), corrupt_crc: true))

      expect_raises(CrystalLLM::Providers::Bedrock::EventStreamError, /CRC/) do
        configured_bedrock.decode_event_stream(io) { |_| }
      end
    end

    it "raises EventStreamError on a truncated frame" do
      full = build_bytes_frame(%({"contentBlockDelta": {"delta": {"text": "x"}}}))
      io = IO::Memory.new(full[0, full.size - 8]) # drop payload tail + CRC

      expect_raises(CrystalLLM::Providers::Bedrock::EventStreamError, /Truncated/) do
        configured_bedrock.decode_event_stream(io) { |_| }
      end
    end

    it "yields nothing for an empty stream (clean EOF)" do
      io = IO::Memory.new(Bytes.new(0))
      count = 0
      configured_bedrock.decode_event_stream(io) { |_| count += 1 }
      count.should eq(0)
    end

    it "drops frames whose payload is not valid JSON" do
      io = IO::Memory.new(build_eventstream_frame("not json at all"))
      count = 0
      configured_bedrock.decode_event_stream(io) { |_| count += 1 }
      count.should eq(0)
    end
  end
end
