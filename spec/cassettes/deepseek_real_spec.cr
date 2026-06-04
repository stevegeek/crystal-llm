# REAL-DATA parser tests for the DeepSeek provider, driven by harvested VCR
# cassette fixtures (spec/fixtures/cassettes/deepseek/*). These are ACTUAL recorded
# DeepSeek responses (not hand-written), so they exercise the real wire shapes the
# parsers must tolerate. DeepSeek is OpenAI-compatible and inherits the whole
# chat/streaming parse surface from Providers::OpenAI (only api_base/headers/
# format_role differ), so these tests double as coverage of the OpenAI parsers
# against real DeepSeek output.
#
# Fixture reality (verified by inspecting the bytes, NOT the file names):
#   chat_1.json / chat_2.json  -> base64-encoded SSE STREAMS (object:
#       "chat.completion.chunk", text content only). Despite the *.json name and
#       chat_ prefix these are streamed bodies, so they are driven through the
#       streaming path (decode base64 -> feed real SSE -> accumulated Message).
#   chat_3.json                -> plain JSON chat.completion (text answer).
#   chat_4.json                -> base64-encoded plain JSON chat.completion (text).
#   stream_1.sse / stream_2.sse-> SSE streams whose deltas carry a tool_call
#       (best_language_to_learn); stream_1 also has leading text content.
#   stream_3.sse / stream_4.sse-> plain text SSE streams ("1, 2, 3.").
#
# (No embedding/image/moderation/transcription cassettes exist for deepseek.)
require "../spec_helper"
require "../../src/crystal_llm/providers/deepseek"
require "../support/stub_connection"

require "base64"

private CASSETTES = File.join(__DIR__, "..", "fixtures", "cassettes", "deepseek")

private def cassette(name : String) : String
  File.read(File.join(CASSETTES, name))
end

# Some DeepSeek cassettes were harvested base64-encoded (the harvester stored the
# raw recorded body as base64 when it was not valid stand-alone JSON, e.g. an SSE
# stream). Detect+decode transparently: a body that does not begin with the JSON
# `{` or an SSE `data:` line is treated as base64.
private def cassette_decoded(name : String) : String
  raw = cassette(name)
  return raw if raw.starts_with?('{') || raw.starts_with?("data:")
  Base64.decode_string(raw)
end

private def configured_deepseek : CrystalLLM::Providers::DeepSeek
  config = CrystalLLM::Configuration.new
  config.deepseek_api_key = "test"
  CrystalLLM::Providers::DeepSeek.new(config)
end

private def deepseek_model(id : String) : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: id, name: id, provider: "deepseek")
end

# Wrap a raw JSON body in a Crest::Response (mirrors spec/provider_spec.cr).
private def response_for(body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(200, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

# Drive the FULL streaming path: the StubConnection replays the real .sse body
# line-by-line, and the accumulator assembles a Message. DeepSeek's stream_url is
# the static "chat/completions" (no model interpolation), but we still render a
# payload first to match the production call order.
private def stream_message(sse_body : String,
                           model : String) : Tuple(CrystalLLM::Message, Array(CrystalLLM::Chunk))
  provider = configured_deepseek
  stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
  provider.connection = stub

  provider.render_payload(
    [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
    tools: {} of String => CrystalLLM::Tool,
    temperature: nil,
    model: deepseek_model(model),
    stream: true
  )

  stub.stub_stream(sse_body)
  chunks = [] of CrystalLLM::Chunk
  message = provider.stream_response("{}") { |chunk| chunks << chunk }
  {message, chunks}
end

describe "DeepSeek real-data parsers" do
  describe "parse_completion_response (plain chat.completion cassettes)" do
    it "chat_3.json: parses a text answer + DeepSeek cache-aware token accounting" do
      provider = configured_deepseek
      message = provider.parse_completion_response(response_for(cassette("chat_3.json")))

      message.should be_a(CrystalLLM::Message)
      message.role.should eq(CrystalLLM::Role::Assistant)

      content = message.content
      content.should be_a(String)
      text = content.as(String)
      text.empty?.should be_false
      text.should contain("weather")
      message.tool_calls.should be_nil

      # usage: prompt 28 (cache_hit 0, miss 28), completion 168, total 196.
      # input_tokens prefers prompt_cache_miss_tokens (28); output is completion.
      message.input_tokens.should eq(28)
      message.output_tokens.should eq(168)
      message.cached_tokens.should eq(0)
      message.model_id.should eq("deepseek-v4-flash")
    end

    it "chat_4.json (base64): parses a long multi-paragraph answer + tokens" do
      provider = configured_deepseek
      message = provider.parse_completion_response(response_for(cassette_decoded("chat_4.json")))

      content = message.content
      content.should be_a(String)
      text = content.as(String)
      text.empty?.should be_false
      text.size.should be > 500 # the recorded answer is ~1.7k chars
      message.tool_calls.should be_nil

      # usage: prompt 210 (miss 210), completion 393, total 603.
      message.input_tokens.should eq(210)
      message.output_tokens.should eq(393)
      message.cached_tokens.should eq(0)
      message.model_id.should eq("deepseek-v4-flash")
    end
  end

  describe "Streaming.stream_response (base64 chat.completion.chunk cassettes)" do
    # chat_1/chat_2 are base64-encoded SSE streams mislabeled as chat_*.json.
    it "chat_1.json: accumulates streamed text deltas into the final answer + final-usage tokens" do
      message, chunks = stream_message(cassette_decoded("chat_1.json"), "deepseek-v4-flash")

      chunks.empty?.should be_false
      content = message.content
      content.should be_a(String)
      text = content.as(String)
      text.empty?.should be_false
      text.should contain("Ruby")
      message.tool_calls.should be_nil

      # final usage event: prompt 342 (cache_hit 256, miss 86), completion 137.
      message.input_tokens.should eq(86)
      message.output_tokens.should eq(137)
      message.cached_tokens.should eq(256)
      message.model_id.should eq("deepseek-v4-flash")
    end

    it "chat_2.json: accumulates streamed text deltas + cache-hit token accounting" do
      message, chunks = stream_message(cassette_decoded("chat_2.json"), "deepseek-v4-flash")

      chunks.empty?.should be_false
      content = message.content
      content.should be_a(String)
      content.as(String).should contain("Ruby")

      # final usage: prompt 539 (cache_hit 512, miss 27), completion 115.
      message.input_tokens.should eq(27)
      message.output_tokens.should eq(115)
      message.cached_tokens.should eq(512)
    end
  end

  describe "Streaming.stream_response (stream_*.sse)" do
    it "stream_3.sse: accumulates a short text answer + tokens" do
      message, chunks = stream_message(cassette("stream_3.sse"), "deepseek-chat")

      chunks.empty?.should be_false
      content = message.content
      content.should be_a(String)
      content.as(String).should eq("1, 2, 3.")
      message.input_tokens.should eq(11)
      message.output_tokens.should eq(8)
    end

    it "stream_4.sse: accumulates a short text answer + tokens" do
      message, chunks = stream_message(cassette("stream_4.sse"), "deepseek-chat")

      chunks.empty?.should be_false
      message.content.should eq("1, 2, 3.")
      message.input_tokens.should eq(11)
      message.output_tokens.should eq(8)
    end

    it "stream_1.sse: captures a streamed tool_call (plus leading text content)" do
      message, chunks = stream_message(cassette("stream_1.sse"), "deepseek-chat")

      chunks.empty?.should be_false

      tool_calls = message.tool_calls
      tool_calls.should_not be_nil
      tc = tool_calls || fail("expected tool_calls, got nil")
      tc.size.should eq(1)
      call = tc.first_value
      call.name.should eq("best_language_to_learn")
      call.id.empty?.should be_false

      # leading content arrived before the tool_call deltas.
      content = message.content
      content.should be_a(String)
      content.as(String).should contain("find that out")

      # final usage: prompt 291 (miss 291), completion 39.
      message.input_tokens.should eq(291)
      message.output_tokens.should eq(39)
    end

    it "stream_2.sse: captures a streamed tool_call with cache-hit tokens (no text)" do
      message, chunks = stream_message(cassette("stream_2.sse"), "deepseek-chat")

      chunks.empty?.should be_false

      tool_calls = message.tool_calls
      tool_calls.should_not be_nil
      tc = tool_calls || fail("expected tool_calls, got nil")
      tc.size.should eq(1)
      tc.first_value.name.should eq("best_language_to_learn")

      # final usage: prompt 495 (cache_hit 384, miss 111), completion 31.
      message.input_tokens.should eq(111)
      message.output_tokens.should eq(31)
      message.cached_tokens.should eq(384)
    end
  end
end
