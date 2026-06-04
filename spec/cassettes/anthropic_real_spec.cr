# REAL-DATA parser tests for the Anthropic provider.
#
# Driven by harvested VCR cassette fixtures under
# spec/fixtures/cassettes/anthropic/ — actual recorded Anthropic Messages-API
# output (claude-haiku-4-5), NOT hand-written. The point is to validate that the
# Crystal port's parsers (parse_completion_response / build_chunk via the
# streaming accumulator) survive real-world response shapes.
#
# Fixture quirks (discovered while wiring this up, see file-bottom NOTE):
# - The cassette bodies are sometimes base64-encoded (ruby_llm's VCR stores some
#   bodies base64); some `chat_*.json` files actually hold an SSE *stream* rather
#   than a single JSON message body. We decode base64 when present and route each
#   fixture to the correct parser by sniffing whether the body is SSE or JSON, so
#   each real payload is exercised through the parser that matches its shape.
#
# Offline only: no network. Streaming fixtures are replayed through a
# StubConnection (the same test affordance the integration specs use); the
# provider's real Streaming#stream_response + StreamAccumulator + build_chunk run.
require "base64"
require "spec"
require "json"
require "crest"
require "http"
require "../support/stub_connection"
require "../../src/crystal_llm"

private FIXTURE_DIR = File.expand_path("../fixtures/cassettes/anthropic", __DIR__)

# A real Anthropic provider with the api key set to "test" (no network is ever
# performed; StubConnection / hand-built Crest::Response stand in).
private def anthropic_provider : CrystalLLM::Providers::Anthropic
  config = CrystalLLM::Configuration.new
  config.anthropic_api_key = "test"
  CrystalLLM::Providers::Anthropic.new(config)
end

# Reads a cassette and decodes base64 when the stored body is base64 (ruby_llm's
# VCR stores some bodies that way). Returns the decoded UTF-8 text.
private def read_cassette(name : String) : String
  raw = File.read(File.join(FIXTURE_DIR, name)).strip
  decode_maybe_base64(raw)
end

# If `raw` is base64 of valid UTF-8 (and not already JSON/SSE), decode it;
# otherwise return it unchanged.
private def decode_maybe_base64(raw : String) : String
  return raw if raw.starts_with?('{') || raw.starts_with?("event:") || raw.starts_with?("data:")
  decoded = Base64.decode_string(raw)
  decoded
rescue Base64::Error
  raw
end

private def sse?(body : String) : Bool
  body.lstrip.starts_with?("event:") || body.lstrip.starts_with?("data:")
end

# Wraps a JSON body in a Crest::Response (the parse_completion_response input),
# mirroring spec/provider_spec.cr.
private def crest_response(body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(200, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

# Drives a real SSE body through the full streaming path:
# StubConnection replays the SSE; provider.stream_response parses each event with
# build_chunk and folds it via the StreamAccumulator into a Message. Returns the
# final Message plus every observed Chunk.
private def stream_to_message(provider : CrystalLLM::Providers::Anthropic,
                              sse_body : String) : Tuple(CrystalLLM::Message, Array(CrystalLLM::Chunk))
  stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
  provider.connection = stub
  stub.stub_stream(sse_body)

  chunks = [] of CrystalLLM::Chunk
  message = provider.stream_response("{}") do |chunk|
    chunks << chunk
  end
  {message, chunks}
end

describe "Anthropic real-data parsers (cassette fixtures)" do
  describe "parse_completion_response (chat_*.json non-streaming bodies)" do
    it "parses a plain text completion (chat_4) into an assistant Message with content + tokens" do
      provider = anthropic_provider
      body = read_cassette("chat_4.json")
      # chat_4 is a single JSON message body (base64-encoded in the cassette).
      sse?(body).should be_false

      msg = provider.parse_completion_response(crest_response(body))

      msg.role.should eq(CrystalLLM::Role::Assistant)
      content = msg.content
      content.should be_a(String)
      content.as(String).should contain("Berlin")
      content.as(String).should contain("Temperature")
      msg.tool_calls.should be_nil

      msg.input_tokens.should eq(748)
      msg.output_tokens.should eq(64)
      msg.model_id.should eq("claude-haiku-4-5-20251001")
    end

    it "parses a tool_use completion (chat_3) into tool_calls with parsed input arguments" do
      provider = anthropic_provider
      body = read_cassette("chat_3.json")
      sse?(body).should be_false

      msg = provider.parse_completion_response(crest_response(body))

      msg.role.should eq(CrystalLLM::Role::Assistant)
      msg.tool_call?.should be_true
      calls = msg.tool_calls
      calls.should_not be_nil
      if calls.nil?
        fail "expected tool_calls to be populated"
      else
        calls.size.should eq(1)
        call = calls.values.first
        call.id.should eq("toolu_01VbeLHMEaVpHF7iASzATfAZ")
        call.name.should eq("weather")
        # Anthropic hands `input` already parsed — args must survive into ToolCall.
        call.arguments["latitude"]?.try(&.as_s).should eq("52.5200")
        call.arguments["longitude"]?.try(&.as_s).should eq("13.4050")
      end

      # tokens still populated on a tool-use turn
      msg.input_tokens.should eq(633)
      msg.output_tokens.should eq(75)
    end

    it "handles cache_creation breakdown without raising (chat_3 carries the nested map)" do
      provider = anthropic_provider
      body = read_cassette("chat_3.json")
      msg = provider.parse_completion_response(crest_response(body))
      # cache_creation_input_tokens is 0 directly; breakdown sums to 0.
      (msg.cache_creation_tokens || 0).should eq(0)
      (msg.cached_tokens || 0).should eq(0)
    end
  end

  describe "streaming (stream_*.sse + the SSE-shaped chat_* fixtures)" do
    it "accumulates a text stream (stream_4) into a Message with the full content + tokens" do
      provider = anthropic_provider
      sse = read_cassette("stream_4.sse")
      sse?(sse).should be_true

      msg, chunks = stream_to_message(provider, sse)

      chunks.empty?.should be_false
      content = msg.content
      content.should be_a(String)
      content.as(String).should contain("Ruby")
      content.as(String).should contain("best language")
      # final message_delta usage carries output_tokens=149; message_start input=633
      msg.input_tokens.should eq(633)
      msg.output_tokens.should eq(149)
      msg.model_id.should eq("claude-haiku-4-5-20251001")

      # the streamed text deltas reassemble to the same content
      streamed = chunks.compact_map { |chunk| chunk.content.as?(String) }.join
      streamed.should eq(content.as(String))
    end

    it "captures a tool_use stream (stream_1) with the tool id + name from content_block_start" do
      provider = anthropic_provider
      sse = read_cassette("stream_1.sse")

      msg, chunks = stream_to_message(provider, sse)

      msg.tool_call?.should be_true
      calls = msg.tool_calls
      if calls.nil?
        fail "expected tool_calls captured from the stream"
      else
        calls.size.should eq(1)
        call = calls.values.first
        call.id.should eq("toolu_01KyLFD3L6qKL1RqXTwTFN8A")
        call.name.should eq("weather")
        # REGRESSION (BUG 1): the input_json_delta partial_json fragments
        # (`{\"latit`, `ud`, `e\": \"52.520`, ...) must concatenate + parse ONCE
        # into the full arguments. Before the fix each fragment parsed to {} and the
        # args were dropped, leaving an EMPTY hash here.
        call.arguments["latitude"]?.try(&.as_s).should eq("52.5200")
        call.arguments["longitude"]?.try(&.as_s).should eq("13.4050")
      end
      msg.input_tokens.should eq(633)
      msg.output_tokens.should eq(75)

      # build_chunk saw at least one input_json_delta tool-call fragment chunk
      chunks.any?(&.tool_call?).should be_true
    end

    it "captures a second tool_use stream (stream_2)" do
      provider = anthropic_provider
      sse = read_cassette("stream_2.sse")
      msg, _ = stream_to_message(provider, sse)

      calls = msg.tool_calls
      if calls.nil?
        fail "expected tool_calls captured from stream_2"
      else
        call = calls.values.first
        call.id.should eq("toolu_01Ag111GSmkLi3svXiNXRJ2Q")
        call.name.should eq("weather")
      end
      msg.output_tokens.should eq(75)
    end

    it "captures a tool_use stream with an empty-arg tool (stream_3)" do
      provider = anthropic_provider
      sse = read_cassette("stream_3.sse")
      msg, _ = stream_to_message(provider, sse)

      calls = msg.tool_calls
      if calls.nil?
        fail "expected tool_calls captured from stream_3"
      else
        call = calls.values.first
        call.id.should eq("toolu_01BwhgbqSCXXpwLPVWXLXYjZ")
        call.name.should eq("best_language_to_learn")
      end
      msg.output_tokens.should eq(41)
    end

    it "accumulates the SSE-shaped chat_1 fixture (a mislabeled stream body) into text + tokens" do
      provider = anthropic_provider
      body = read_cassette("chat_1.json")
      # chat_1's cassette body is actually an SSE stream, not a JSON message.
      sse?(body).should be_true

      msg, _ = stream_to_message(provider, body)
      content = msg.content
      content.should be_a(String)
      content.as(String).should contain("Berlin")
      msg.input_tokens.should eq(748)
      msg.output_tokens.should eq(42)
    end

    # REGRESSION (BUG 4): a streaming error event must be RAISED as a mapped
    # CrystalLLM error, not fed to build_chunk (which would silently swallow it).
    it "raises a mapped CrystalLLM error on an `event: error` stream event" do
      provider = anthropic_provider
      error_sse = <<-SSE
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


        SSE

      expect_raises(CrystalLLM::OverloadedError, /Overloaded/) do
        stream_to_message(provider, error_sse)
      end
    end

    # An error data payload (no `event: error`, but an `"error"` key) is also raised.
    it "raises when a data payload carries an `error` key" do
      provider = anthropic_provider
      error_sse = <<-SSE
        data: {"type":"error","error":{"type":"overloaded_error","message":"boom"}}


        SSE

      expect_raises(CrystalLLM::OverloadedError, /boom/) do
        stream_to_message(provider, error_sse)
      end
    end

    it "accumulates the SSE-shaped chat_2 fixture into text + tokens" do
      provider = anthropic_provider
      body = read_cassette("chat_2.json")
      sse?(body).should be_true

      msg, _ = stream_to_message(provider, body)
      content = msg.content
      content.should be_a(String)
      content.as(String).should contain("Paris")
      msg.input_tokens.should eq(927)
      msg.output_tokens.should eq(50)
    end
  end
end

# NOTE (fixture provenance, for the next reader):
# - chat_3.json is the only raw-JSON non-streaming body (a tool_use turn).
# - chat_4.json is a base64-encoded non-streaming JSON body (a text turn).
# - chat_1.json / chat_2.json are base64-encoded *SSE streams* (text turns) —
#   mislabeled as .json in the harvest; routed through the streaming path here.
# - stream_{1,2,3}.sse are tool_use streams (input_json_delta fragments);
#   stream_4.sse is a text stream.
#
# Anthropic streaming tool-call arguments: the partial_json fragments
# (`{\"latit`, `ud`, ...) are individually unparseable. The provider carries each
# raw fragment String on ToolCall#raw_arguments; the StreamAccumulator concatenates
# them and JSON.parses the whole once in to_message (matching ruby_llm). So a
# streamed tool call lands with its id + name AND the fully reconstructed arguments
# (latitude/longitude above) — the stream_1 test asserts both.
