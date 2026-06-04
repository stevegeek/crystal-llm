# REAL-DATA parser tests for the OpenRouter provider.
#
# Driven by harvested VCR cassette fixtures at spec/fixtures/cassettes/openrouter/.
# These are ACTUAL recorded OpenRouter responses (from ruby_llm's VCR cassettes),
# not hand-written. OpenRouter is an OpenAI-compatible aggregator, so the provider
# subclasses OpenAI and inherits parse_completion_response / build_chunk unchanged
# (see openrouter.cr header). The point is to validate those inherited parsers
# against real-world OpenRouter wire shapes.
#
# Fixtures present (ls of the dir):
#   chat_1.json   non-streaming, content:null, no tool_calls (real "empty" shape)
#   chat_2.json   non-streaming text answer ("5 + 3 = 8") + reasoning tokens
#   chat_3.json   non-streaming text answer ("8 x 2 = 16"), stored BASE64-encoded
#   chat_4.json   non-streaming tool_call (any_of_params)
#   stream_1.sse  streaming tool_call (best_language_to_learn)
#   stream_2.sse  streaming text answer + final usage
#   stream_3.sse  streaming tool_call (best_language_to_learn)
#   stream_4.sse  streaming text answer + final usage
#
# FIXTURE NOTE: chat_3.json is stored base64-encoded in the harvest; the others
# are raw JSON (with some leading whitespace, which JSON.parse tolerates). Real
# OpenRouter bodies are raw JSON, so read_cassette_json decodes base64 when the
# body isn't already valid JSON.
#
# NO network: chat tests call the pure parse hook directly; stream tests inject a
# StubConnection (canned SSE) and drive the real Streaming.stream_response path.
require "spec"
require "base64"
require "../../src/crystal_llm"
require "../support/stub_connection"

private FIXTURE_DIR = File.expand_path("../fixtures/cassettes/openrouter", __DIR__)

# Build an OpenRouter provider whose required config key is set to "test".
private def build_openrouter_provider : CrystalLLM::Providers::OpenRouter
  config = CrystalLLM::Configuration.new
  config.openrouter_api_key = "test"
  CrystalLLM::Providers::OpenRouter.new(config)
end

# Wrap a raw body string in a Crest::Response (mirrors spec/provider_spec.cr).
private def crest_response(body : String, status : Int32 = 200) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

# Read a cassette body, normalizing the harvest's mixed encoding: chat_3 is
# stored base64-encoded. Real OpenRouter bodies are raw JSON, so decode base64
# when the body isn't already valid JSON.
private def read_cassette_json(path : String) : String
  body = File.read(path).strip
  begin
    JSON.parse(body)
    body
  rescue JSON::ParseException
    decoded = Base64.decode_string(body.gsub(/\s/, ""))
    JSON.parse(decoded) # raises (failing the test) if this isn't JSON either
    decoded
  end
end

# Pull the plain text out of a Message#content union (String | Content | Nil).
private def text_of(content : String | CrystalLLM::Content | Nil) : String?
  case content
  when String              then content
  when CrystalLLM::Content then content.text
  else                          nil
  end
end

# Drive the REAL streaming path: inject a StubConnection seeded with the raw
# recorded SSE, then call stream_response (which feeds the SSE through SSE +
# build_chunk + StreamAccumulator) and return the assembled Message + the
# per-chunk yields.
private def stream_message(sse_path : String) : {CrystalLLM::Message, Array(CrystalLLM::Chunk)}
  provider = build_openrouter_provider
  config = CrystalLLM::Configuration.new
  config.openrouter_api_key = "test"
  stub = CrystalLLM::Spec::StubConnection.new(provider, config)
  stub.stub_stream(File.read(sse_path))
  provider.connection = stub

  chunks = [] of CrystalLLM::Chunk
  message = provider.stream_response("{}") do |chunk|
    chunks << chunk
  end
  {message, chunks}
end

describe "OpenRouter provider real-data parsing" do
  describe "parse_completion_response (chat_*.json)" do
    it "chat_1: real content:null shape parses cleanly with token counts" do
      provider = build_openrouter_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "chat_1.json"))

      message = provider.parse_completion_response(crest_response(body))

      message.should be_a(CrystalLLM::Message)
      message.role.should eq(CrystalLLM::Role::Assistant)
      # This recorded response genuinely has content:null and no tool_calls.
      message.content.should be_nil
      message.tool_calls.should be_nil

      # Token counts must still be populated from `usage`.
      input = message.input_tokens
      output = message.output_tokens
      fail "chat_1: expected input_tokens populated" if input.nil?
      fail "chat_1: expected output_tokens populated" if output.nil?
      input.should eq(633)
      output.should eq(9)
      message.model_id.should eq("anthropic/claude-4.5-haiku-20251001")
    end

    it "chat_2: text answer '5 + 3 = 8' + reasoning tokens" do
      provider = build_openrouter_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "chat_2.json"))

      message = provider.parse_completion_response(crest_response(body))

      text = text_of(message.content)
      fail "chat_2: expected non-nil text content, got #{message.content.inspect}" if text.nil?
      text.should contain("5 + 3 = 8")

      message.input_tokens.should eq(45)
      message.output_tokens.should eq(39)
      # completion_tokens_details.reasoning_tokens = 15
      message.thinking_tokens.should eq(15)
      message.tool_calls.should be_nil
    end

    it "chat_3: BASE64-encoded fixture decodes to text answer '8 x 2 = 16'" do
      provider = build_openrouter_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "chat_3.json"))

      message = provider.parse_completion_response(crest_response(body))

      text = text_of(message.content)
      fail "chat_3: expected non-nil text content, got #{message.content.inspect}" if text.nil?
      text.should contain("16")

      message.input_tokens.should eq(67)
      message.output_tokens.should eq(47)
      message.thinking_tokens.should eq(21)
    end

    it "chat_4: tool_call any_of_params with parsed arguments" do
      provider = build_openrouter_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "chat_4.json"))

      message = provider.parse_completion_response(crest_response(body))

      message.tool_call?.should be_true
      calls = message.tool_calls
      fail "chat_4: expected tool_calls" if calls.nil?
      calls.size.should eq(1)

      call = calls.values.first
      call.name.should eq("any_of_params")
      call.id.should eq("toolu_bdrk_01SdFjL2epCuvP6uSeXJa5tq")
      # arguments were a JSON STRING on the wire; parser must decode to a Hash.
      call.arguments["task"]?.try(&.as_s?).should eq("Review PR")
      call.arguments["status"]?.try(&.as_s?).should eq("pending")

      message.input_tokens.should eq(646)
      message.output_tokens.should eq(74)
    end
  end

  describe "streaming (stream_*.sse) via Streaming.stream_response" do
    it "stream_2: text chunks accumulate to a full answer + final usage" do
      message, chunks = stream_message(File.join(FIXTURE_DIR, "stream_2.sse"))

      chunks.empty?.should be_false
      text = text_of(message.content)
      fail "stream_2: expected accumulated text content" if text.nil?
      text.empty?.should be_false
      text.should contain("Ruby")

      # final usage event: total_tokens 843
      fail "stream_2: expected output_tokens from final usage" if message.output_tokens.nil?
      message.input_tokens.should eq(633)
      message.output_tokens.should eq(210)
    end

    it "stream_4: text chunks accumulate to a full answer + final usage" do
      message, chunks = stream_message(File.join(FIXTURE_DIR, "stream_4.sse"))

      chunks.empty?.should be_false
      text = text_of(message.content)
      fail "stream_4: expected accumulated text content" if text.nil?
      text.empty?.should be_false
      text.should contain("Ruby")

      fail "stream_4: expected output_tokens from final usage" if message.output_tokens.nil?
      message.input_tokens.should_not be_nil
    end

    it "stream_1: streamed tool_call deltas accumulate into a ToolCall" do
      message, chunks = stream_message(File.join(FIXTURE_DIR, "stream_1.sse"))

      chunks.empty?.should be_false
      message.tool_call?.should be_true
      calls = message.tool_calls
      fail "stream_1: expected tool_calls" if calls.nil?

      call = calls.values.first
      call.name.should eq("best_language_to_learn")
      call.id.should eq("toolu_bdrk_01XHzDZs8qR74VjLUhitDdUA")

      # usage arrives on the final delta: total_tokens 620
      fail "stream_1: expected output_tokens from final usage" if message.output_tokens.nil?
      message.output_tokens.should_not be_nil
    end

    it "stream_3: streamed tool_call deltas accumulate into a ToolCall" do
      message, chunks = stream_message(File.join(FIXTURE_DIR, "stream_3.sse"))

      chunks.empty?.should be_false
      message.tool_call?.should be_true
      calls = message.tool_calls
      fail "stream_3: expected tool_calls" if calls.nil?

      call = calls.values.first
      call.name.should eq("best_language_to_learn")

      fail "stream_3: expected output_tokens from final usage" if message.output_tokens.nil?
    end
  end
end
