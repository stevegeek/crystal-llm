# REAL-DATA parser tests for the VertexAI (Gemini wire format) provider.
#
# Driven by harvested VCR cassette fixtures under
# spec/fixtures/cassettes/vertexai/ — actual recorded provider output, not
# hand-written shapes. The point is to validate our parsers (parse_completion_response
# and the streaming build_chunk path) survive real-world Gemini/Vertex responses.
#
# Fixtures present for this provider: chat_{1..4}.json, stream_{1..4}.sse.
# (No embedding/image/moderation/transcription cassettes were harvested for vertexai.)
#
# NOTE: some chat_*.json fixtures are stored base64-encoded (the VCR recorder
# base64-encodes bodies it deems non-UTF8-safe). `read_json_cassette` transparently
# decodes those so the parser sees the same JSON the live wire would deliver.
require "base64"
require "../spec_helper"
require "../../src/crystal_llm/providers/vertexai"
require "../support/stub_connection"

private CASSETTE_DIR = File.expand_path("../fixtures/cassettes/vertexai", __DIR__)

# Reads a JSON chat cassette, transparently decoding the base64-wrapped ones.
private def read_json_cassette(name : String) : String
  raw = File.read(File.join(CASSETTE_DIR, name))
  begin
    JSON.parse(raw)
    raw
  rescue JSON::ParseException
    Base64.decode_string(raw.strip)
  end
end

# Reads an SSE cassette verbatim (the streaming path parses it line by line).
private def read_sse_cassette(name : String) : String
  File.read(File.join(CASSETTE_DIR, name))
end

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

private def configured_vertexai : CrystalLLM::Providers::VertexAI
  config = CrystalLLM::Configuration.new
  config.vertexai_project_id = "my-project"
  config.vertexai_location = "us-central1"
  config.vertexai_service_account_key = "test"
  CrystalLLM::Providers::VertexAI.new(config)
end

private def gemini_model : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", provider: "vertexai")
end

# Drive the real SSE body through the full streaming path (StubConnection ->
# stream_response -> SSE parse -> build_chunk -> StreamAccumulator) and return the
# accumulated final Message plus the per-event chunks captured along the way.
private def stream_cassette(provider : CrystalLLM::Providers::VertexAI,
                            sse_body : String) : Tuple(CrystalLLM::Message, Array(CrystalLLM::Chunk))
  config = CrystalLLM::Configuration.new
  config.vertexai_project_id = "my-project"
  config.vertexai_location = "us-central1"
  config.vertexai_service_account_key = "test"
  stub = CrystalLLM::Spec::StubConnection.new(provider, config)
  stub.stub_stream(sse_body)
  provider.connection = stub

  # render_payload captures @last_model so stream_url can be built.
  provider.render_payload(
    [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
    tools: {} of String => CrystalLLM::Tool,
    temperature: nil,
    model: gemini_model,
    stream: true
  )

  chunks = [] of CrystalLLM::Chunk
  message = provider.stream_response("{}") { |chunk| chunks << chunk }
  {message, chunks}
end

describe "VertexAI real cassette parsing" do
  describe "parse_completion_response (chat_*.json)" do
    it "chat_1: parses a plain text beach-description completion with tokens" do
      provider = configured_vertexai
      message = provider.parse_completion_response(build_response(200, read_json_cassette("chat_1.json")))

      message.role.should eq(CrystalLLM::Role::Assistant)
      content = message.content
      content.should be_a(String)
      raise "expected string content" unless content.is_a?(String)
      content.empty?.should be_false
      content.should contain("serene beach scene")
      message.tool_call?.should be_false

      # usageMetadata: prompt 3362, cached 2993 -> input 369; candidates 191 + thoughts 886 -> output 1077.
      message.input_tokens.should eq(369)
      message.output_tokens.should eq(1077)
      message.cached_tokens.should eq(2993)
      message.thinking_tokens.should eq(886)
      message.model_id.should eq("gemini-2.5-flash")
    end

    it "chat_2: keeps the non-thought answer part and drops the thought part" do
      provider = configured_vertexai
      message = provider.parse_completion_response(build_response(200, read_json_cassette("chat_2.json")))

      content = message.content
      raise "expected string content" unless content.is_a?(String)
      # The thought part ("My Thought Process...") must be excluded; only the
      # visible answer survives.
      content.should eq("5 + 3 = 8")
      content.should_not contain("Thought Process")

      message.input_tokens.should eq(8)   # prompt 8, no cache
      message.output_tokens.should eq(42) # candidates 7 + thoughts 35
      message.thinking_tokens.should eq(35)
      message.model_id.should eq("gemini-3-flash-preview")
    end

    it "chat_3: decodes the base64-wrapped body and keeps only the answer part" do
      provider = configured_vertexai
      message = provider.parse_completion_response(build_response(200, read_json_cassette("chat_3.json")))

      content = message.content
      raise "expected string content" unless content.is_a?(String)
      content.should eq("8 × 2 = 16")
      content.should_not contain("Thought Process")

      message.input_tokens.should eq(21)  # prompt 21
      message.output_tokens.should eq(36) # candidates 8 + thoughts 28
      message.thinking_tokens.should eq(28)
      message.model_id.should eq("gemini-3-flash-preview")
    end

    it "chat_4: parses a functionCall part into a tool call (no text content)" do
      provider = configured_vertexai
      message = provider.parse_completion_response(build_response(200, read_json_cassette("chat_4.json")))

      message.tool_call?.should be_true
      # Only a functionCall part, no text. An assistant tool-call message with no
      # text normalizes to "" (Message#normalize_content, mirroring ruby_llm).
      message.content.should eq("")

      calls = message.tool_calls
      raise "expected tool calls" unless calls
      calls.size.should eq(1)
      call = calls.first_value
      call.name.should eq("weather")
      call.arguments["longitude"].as_s.should eq("13.4050")
      call.arguments["latitude"].as_s.should eq("52.5200")
      # The recorded part carried a thoughtSignature -> must be captured.
      call.thought_signature.should_not be_nil

      message.input_tokens.should eq(70)
      message.output_tokens.should eq(70) # candidates 17 + thoughts 53
      message.model_id.should eq("gemini-2.5-flash")
    end
  end

  describe "streaming build_chunk path (stream_*.sse)" do
    it "stream_1: accumulates text deltas into a Message with content + tokens" do
      provider = configured_vertexai
      message, chunks = stream_cassette(provider, read_sse_cassette("stream_1.sse"))

      chunks.empty?.should be_false
      content = message.content
      raise "expected string content" unless content.is_a?(String)
      content.should eq("1\n2\n3")
      message.tool_call?.should be_false

      message.input_tokens.should eq(7)
      message.output_tokens.should eq(26) # candidates 5 + thoughts 21
      message.model_id.should eq("gemini-2.5-flash")
    end

    it "stream_2: accumulates text deltas (second recorded run)" do
      provider = configured_vertexai
      message, chunks = stream_cassette(provider, read_sse_cassette("stream_2.sse"))

      chunks.empty?.should be_false
      content = message.content
      raise "expected string content" unless content.is_a?(String)
      content.should eq("1\n2\n3")
      message.input_tokens.should eq(7)
      message.output_tokens.should eq(25) # candidates 5 + thoughts 20
    end

    it "stream_3: captures a streamed functionCall tool call" do
      provider = configured_vertexai
      message, chunks = stream_cassette(provider, read_sse_cassette("stream_3.sse"))

      chunks.empty?.should be_false
      message.tool_call?.should be_true

      calls = message.tool_calls
      raise "expected tool calls" unless calls
      calls.size.should eq(1)
      call = calls.first_value
      call.name.should eq("weather")
      call.arguments["latitude"].as_s.should eq("52.5200")
      call.arguments["longitude"].as_s.should eq("13.4050")
      call.thought_signature.should_not be_nil

      message.input_tokens.should eq(70)
      message.output_tokens.should eq(83) # candidates 17 + thoughts 66
    end

    it "stream_4: captures a streamed functionCall tool call (Paris coords)" do
      provider = configured_vertexai
      message, _ = stream_cassette(provider, read_sse_cassette("stream_4.sse"))

      message.tool_call?.should be_true
      calls = message.tool_calls
      raise "expected tool calls" unless calls
      call = calls.first_value
      call.name.should eq("weather")
      call.arguments["latitude"].as_s.should eq("48.8575")
      call.arguments["longitude"].as_s.should eq("2.3514")

      message.input_tokens.should eq(190)
      message.output_tokens.should eq(62) # candidates 16 + thoughts 46
    end
  end
end
