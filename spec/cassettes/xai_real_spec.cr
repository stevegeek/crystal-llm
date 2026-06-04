# REAL-DATA parser tests for the xAI (Grok) provider.
#
# Driven by harvested VCR cassette fixtures under
# spec/fixtures/cassettes/xai/ — actual recorded xAI wire responses, NOT
# hand-written. The point is to validate the (inherited OpenAI) parsers against
# real-world shapes.
#
# Fixture inventory for this provider (ls'd):
#   chat_1.json, chat_2.json  -> BASE64-encoded SSE *streams* (mislabeled .json;
#                                decoded body is `data: {...chunk...}` ... [DONE]).
#   chat_3.json, chat_4.json  -> plain JSON non-streaming chat.completion responses
#                                (chat_3 = tool_calls, chat_4 = text content).
#   stream_1.sse, stream_2.sse -> SSE streams ending in a single tool_calls delta.
#   stream_3.sse               -> long text SSE stream.
#   stream_4.sse               -> short text SSE stream.
#   (no embedding_/image_/moderation_/transcription_ fixtures for xai.)
require "spec"
require "base64"
require "../../src/crystal_llm"
require "../support/stub_connection"

# Build a Crest::Response over an in-memory body (mirrors spec/provider_spec.cr).
private def cassette_response(body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(200, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

private def xai_provider : CrystalLLM::Providers::XAI
  config = CrystalLLM::Configuration.new
  config.xai_api_key = "test"
  CrystalLLM::Providers::XAI.new(config)
end

private def fixture_dir : String
  File.join(__DIR__, "..", "fixtures", "cassettes", "xai")
end

private def read_fixture(name : String) : String
  File.read(File.join(fixture_dir, name))
end

# Drive the OpenAI/xAI streaming path (Streaming#stream_response) over a real SSE
# body, returning the accumulated final Message plus the per-chunk list.
private def stream_via_provider(sse_body : String) : Tuple(CrystalLLM::Message, Array(CrystalLLM::Chunk))
  provider = xai_provider
  config = provider.config
  stub = CrystalLLM::Spec::StubConnection.new(provider, config)
  stub.stub_stream(sse_body)
  provider.connection = stub

  chunks = [] of CrystalLLM::Chunk
  message = provider.stream_response("{}") do |chunk|
    chunks << chunk
  end
  {message, chunks}
end

describe "xAI provider — real cassette data" do
  describe "parse_completion_response (chat_*.json plain-JSON responses)" do
    it "parses chat_4 text completion into a Message with content + tokens" do
      provider = xai_provider
      resp = cassette_response(read_fixture("chat_4.json"))

      message = provider.parse_completion_response(resp)

      message.should be_a(CrystalLLM::Message)
      message.role.should eq(CrystalLLM::Role::Assistant)

      content = message.content
      content.should be_a(String)
      content.as(String).should eq("The three dice rolls are: 1, 2, 3.")

      message.model_id.should eq("grok-4-1-fast-non-reasoning")
      # tokens populated from real usage block
      message.output_tokens.should eq(15)
      # cached_tokens = 387, so input = prompt(469) - cached(387) = 82
      message.cached_tokens.should eq(387)
      input = message.input_tokens
      input.should_not be_nil
      input.as(Int32).should eq(82)
      message.tool_call?.should be_false
    end

    it "parses chat_3 tool-call completion into a Message with tool_calls + tokens" do
      provider = xai_provider
      resp = cassette_response(read_fixture("chat_3.json"))

      message = provider.parse_completion_response(resp)

      message.tool_call?.should be_true
      tcs = message.tool_calls
      tcs.should_not be_nil
      calls = tcs.as(Hash(String, CrystalLLM::ToolCall))
      calls.size.should be > 0
      # every recorded call targets the dice_roll tool
      calls.each_value do |call|
        call.name.should eq("dice_roll")
        call.id.should_not be_empty
      end

      message.model_id.should eq("grok-4-1-fast-non-reasoning")
      message.output_tokens.should eq(45)
      message.cached_tokens.should eq(159)
    end
  end

  describe "streaming over base64-encoded SSE (chat_1/chat_2.json)" do
    it "accumulates chat_1 base64 SSE stream into a text Message with tokens" do
      sse = Base64.decode_string(read_fixture("chat_1.json"))
      message, chunks = stream_via_provider(sse)

      chunks.empty?.should be_false
      content = message.content
      content.should be_a(String)
      content.as(String).should contain("current")
      content.as(String).empty?.should be_false

      message.model_id.should eq("grok-4-1-fast-non-reasoning")
      # final usage chunk: prompt 493, completion 29, cached 158 -> input 335
      message.output_tokens.should eq(29)
      message.cached_tokens.should eq(158)
      message.input_tokens.should eq(335)
    end

    it "accumulates chat_2 base64 SSE stream into a non-empty text Message" do
      sse = Base64.decode_string(read_fixture("chat_2.json"))
      message, chunks = stream_via_provider(sse)

      chunks.empty?.should be_false
      content = message.content
      content.should be_a(String)
      content.as(String).empty?.should be_false
      message.output_tokens.should_not be_nil
    end
  end

  describe "streaming over .sse fixtures (text)" do
    it "accumulates stream_4 short text stream to '1, 2, 3.' with tokens" do
      message, chunks = stream_via_provider(read_fixture("stream_4.sse"))

      chunks.empty?.should be_false
      message.content.should eq("1, 2, 3.")
      message.output_tokens.should eq(8)
      message.input_tokens.should_not be_nil
    end

    it "accumulates stream_3 long text stream into a 1689-char Message" do
      message, chunks = stream_via_provider(read_fixture("stream_3.sse"))

      chunks.empty?.should be_false
      content = message.content
      content.should be_a(String)
      text = content.as(String)
      text.size.should eq(1689)
      text.should start_with("To see your future self")
      # Real cassette quirk: this stream's final usage is
      # prompt=50, completion=360, total=4200 (total != prompt+completion).
      # The ported OpenAI `output_tokens` returns max(total-prompt, completion)
      # = max(4150, 360) = 4150 — generated-from-total wins when larger (the
      # reasoning-model accounting path). Asserting the parser's real contract.
      message.output_tokens.should eq(4150)
      # prompt=50, cached=49 -> input = max(50 - 49, 0) = 1
      message.input_tokens.should eq(1)
      message.cached_tokens.should eq(49)
    end
  end

  describe "streaming over .sse fixtures (tool calls)" do
    it "captures stream_1's single weather tool_call delta with merged arguments" do
      message, chunks = stream_via_provider(read_fixture("stream_1.sse"))

      chunks.empty?.should be_false
      message.tool_call?.should be_true
      tcs = message.tool_calls
      tcs.should_not be_nil
      calls = tcs.as(Hash(String, CrystalLLM::ToolCall))
      calls.size.should eq(1)

      call = calls["call_27949965"]?
      call.should_not be_nil
      tc = call.as(CrystalLLM::ToolCall)
      tc.name.should eq("weather")
      # arguments accumulated from the streamed (full) fragment
      tc.arguments["latitude"]?.try(&.as_s).should eq("52.5200")
      tc.arguments["longitude"]?.try(&.as_s).should eq("13.4050")

      # final usage chunk wired through
      message.output_tokens.should eq(40)
      message.cached_tokens.should eq(158)
    end

    it "captures stream_2's weather tool_call (Paris coords)" do
      message, _ = stream_via_provider(read_fixture("stream_2.sse"))

      message.tool_call?.should be_true
      calls = message.tool_calls.as(Hash(String, CrystalLLM::ToolCall))
      calls.size.should eq(1)
      tc = calls.first_value
      tc.name.should eq("weather")
      tc.arguments["latitude"]?.try(&.as_s).should eq("48.8575")
      tc.arguments["longitude"]?.try(&.as_s).should eq("2.3514")
      message.output_tokens.should eq(40)
    end
  end
end
