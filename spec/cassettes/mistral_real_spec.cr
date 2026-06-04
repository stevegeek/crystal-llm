# REAL-DATA parser tests for the Mistral provider, driven by harvested VCR
# cassette fixtures (spec/fixtures/cassettes/mistral/*). These are ACTUAL recorded
# Mistral responses (not hand-written), so they exercise the real wire shapes the
# parsers (inherited from Providers::OpenAI, with Mistral overrides) must tolerate.
#
# Coverage (whatever EXISTS for mistral):
#   chat_3.json / chat_4.json -> parse_completion_response -> Message (content + tokens)
#   chat_1.json / chat_2.json -> these are NOT completion JSON: they are base64-
#     encoded SSE streams (a `data: {chat.completion.chunk}` event log). They get
#     decoded and driven through the streaming path, same as the .sse files.
#   stream_*.sse -> Streaming.stream_response (via StubConnection) -> accumulated
#     Message. stream_1/stream_2 are tool-call streams; stream_3/stream_4 are text.
#   embedding_1.json -> parse_embedding_response -> Embedding with non-empty vectors
#
# (No image/moderation/transcription cassettes for mistral.)
require "../spec_helper"
require "../../src/crystal_llm/providers/mistral"
require "../support/stub_connection"
require "base64"

private CASSETTES = File.join(__DIR__, "..", "fixtures", "cassettes", "mistral")

private def cassette(name : String) : String
  File.read(File.join(CASSETTES, name))
end

# chat_1.json / chat_2.json are base64-encoded SSE bodies (recorded as a single
# blob). Decode to the raw `data: ...` SSE text.
private def decoded_sse(name : String) : String
  Base64.decode_string(cassette(name).strip)
end

private def configured_mistral : CrystalLLM::Providers::Mistral
  config = CrystalLLM::Configuration.new
  config.mistral_api_key = "test"
  CrystalLLM::Providers::Mistral.new(config)
end

private def mistral_model(id : String) : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: id, name: id, provider: "mistral")
end

# Wrap a raw JSON body in a Crest::Response (mirrors spec/provider_spec.cr).
private def response_for(body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(200, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

# Drives the FULL streaming path: render_payload primes the provider, the
# StubConnection replays the SSE body line-by-line, and the accumulator assembles
# a Message. Returns {message, chunks}.
private def stream_message(sse_body : String,
                           model : String) : Tuple(CrystalLLM::Message, Array(CrystalLLM::Chunk))
  provider = configured_mistral
  stub = CrystalLLM::Spec::StubConnection.new(provider, CrystalLLM.config)
  provider.connection = stub

  provider.render_payload(
    [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
    tools: {} of String => CrystalLLM::Tool,
    temperature: nil,
    model: mistral_model(model),
    stream: true
  )

  stub.stub_stream(sse_body)
  chunks = [] of CrystalLLM::Chunk
  message = provider.stream_response("{}") { |chunk| chunks << chunk }
  {message, chunks}
end

describe "Mistral real-data parsers" do
  describe "parse_completion_response (chat_*.json)" do
    it "chat_3.json: parses a short text answer + token counts" do
      provider = configured_mistral
      message = provider.parse_completion_response(response_for(cassette("chat_3.json")))

      message.should be_a(CrystalLLM::Message)
      message.role.should eq(CrystalLLM::Role::Assistant)
      message.tool_calls.should be_nil

      content = message.content
      content.should be_a(String)
      text = content.as(String)
      text.empty?.should be_false
      text.should contain("Paris")

      # usage: prompt_tokens 22, total 60, completion 38 -> output = max(total-prompt,
      # completion) = 38; input = prompt - cached(0) = 22.
      message.input_tokens.should eq(22)
      message.output_tokens.should eq(38)
      message.model_id.should eq("mistral-small-latest")
    end

    it "chat_4.json: parses a long multi-paragraph answer + token counts" do
      provider = configured_mistral
      message = provider.parse_completion_response(response_for(cassette("chat_4.json")))

      content = message.content
      content.should be_a(String)
      text = content.as(String)
      text.empty?.should be_false
      text.should contain("Ruby")
      message.tool_calls.should be_nil

      # usage: prompt 589, total 889, completion 300.
      message.input_tokens.should eq(589)
      message.output_tokens.should eq(300)
      message.model_id.should eq("mistral-small-latest")
    end
  end

  describe "streaming completion (chat_1/chat_2 base64 SSE)" do
    # chat_1.json / chat_2.json are NOT completion JSON — they are base64-encoded
    # SSE streams. Decode + drive them through the streaming accumulator.
    it "chat_1.json: accumulates the weather text answer + tokens" do
      message, chunks = stream_message(decoded_sse("chat_1.json"), "mistral-small-latest")

      chunks.empty?.should be_false
      content = message.content
      content.should be_a(String)
      content.as(String).should eq(
        "The current weather in Berlin (52.5200, 13.4050) is **15°C** with a wind speed of **10 km/h**."
      )
      message.tool_calls.should be_nil
      # final usage chunk: prompt 222, total 263, completion 41.
      message.input_tokens.should eq(222)
      message.output_tokens.should eq(41)
      message.model_id.should eq("mistral-small-latest")
    end

    it "chat_2.json: accumulates the weather text answer + tokens" do
      message, chunks = stream_message(decoded_sse("chat_2.json"), "mistral-small-latest")

      chunks.empty?.should be_false
      content = message.content
      content.should be_a(String)
      content.as(String).should eq(
        "The current weather in Paris (48.8575, 2.3514) is **15°C** with a wind speed of **10 km/h**."
      )
      message.input_tokens.should eq(350)
      message.output_tokens.should eq(40)
    end
  end

  describe "Streaming.stream_response (stream_*.sse)" do
    it "stream_3.sse: accumulates text deltas into the final answer + tokens" do
      message, chunks = stream_message(cassette("stream_3.sse"), "mistral-small-latest")

      # 4 data events (role-only, "1", ", 2,", " 3"); the role-only first event
      # still produces a chunk.
      chunks.empty?.should be_false
      message.content.should eq("1, 2, 3")
      message.tool_calls.should be_nil
      # final usage chunk: prompt 22, total 30, completion 8.
      message.input_tokens.should eq(22)
      message.output_tokens.should eq(8)
      message.model_id.should eq("mistral-small-latest")
    end

    it "stream_4.sse: accumulates text deltas into the final answer + tokens" do
      message, chunks = stream_message(cassette("stream_4.sse"), "mistral-small-latest")

      chunks.empty?.should be_false
      message.content.should eq("1, 2, 3")
      message.input_tokens.should eq(22)
      message.output_tokens.should eq(8)
    end

    it "stream_1.sse: captures a streamed tool_call (weather) with arguments + tokens" do
      message, chunks = stream_message(cassette("stream_1.sse"), "mistral-small-latest")

      chunks.empty?.should be_false
      tool_calls = message.tool_calls
      tool_calls.should_not be_nil
      tc = tool_calls || fail("expected tool_calls, got nil")
      tc.size.should eq(1)

      call = tc.first_value
      call.id.should eq("VC2uL97hE")
      call.name.should eq("weather")
      call.arguments["latitude"]?.try(&.as_s?).should eq("52.5200")
      call.arguments["longitude"]?.try(&.as_s?).should eq("13.4050")

      # tool_calls chunk carries usage: prompt 159, total 187, completion 28.
      message.input_tokens.should eq(159)
      message.output_tokens.should eq(28)
      message.model_id.should eq("mistral-small-latest")
    end

    it "stream_2.sse: captures a streamed tool_call (weather) with arguments + tokens" do
      message, chunks = stream_message(cassette("stream_2.sse"), "mistral-small-latest")

      chunks.empty?.should be_false
      tool_calls = message.tool_calls
      tool_calls.should_not be_nil
      tc = tool_calls || fail("expected tool_calls, got nil")
      tc.size.should eq(1)

      call = tc.first_value
      call.id.should eq("6ZsbiM2Yb")
      call.name.should eq("weather")
      call.arguments["latitude"]?.try(&.as_s?).should eq("48.8575")
      call.arguments["longitude"]?.try(&.as_s?).should eq("2.3514")

      # prompt 289, total 316, completion 27.
      message.input_tokens.should eq(289)
      message.output_tokens.should eq(27)
    end
  end

  describe "parse_embedding_response (embedding_1.json)" do
    it "flattens a single-row embed (String input) to a flat non-empty vector" do
      provider = configured_mistral
      embedding = provider.parse_embedding_response(
        response_for(cassette("embedding_1.json")),
        model: "mistral-embed",
        text: "hello"
      )

      embedding.should be_a(CrystalLLM::Embedding)
      embedding.model.should eq("mistral-embed")
      # usage.prompt_tokens 11.
      embedding.input_tokens.should eq(11)

      vectors = embedding.vectors
      # One returned row + non-Array input -> flatten to a single flat vector.
      vectors.should be_a(Array(Float64))
      if vectors.is_a?(Array(Float64))
        vectors.size.should eq(1024)
        # spot-check a real recorded value.
        vectors[0].should be_close(-0.048187255859375, 1e-12)
      end
    end

    it "keeps the batch (nested) shape for an Array input" do
      provider = configured_mistral
      embedding = provider.parse_embedding_response(
        response_for(cassette("embedding_1.json")),
        model: "mistral-embed",
        text: ["hello"]
      )

      vectors = embedding.vectors
      # Array input -> never flattened, even with a single row.
      vectors.should be_a(Array(Array(Float64)))
      if vectors.is_a?(Array(Array(Float64)))
        vectors.size.should eq(1)
        vectors[0].size.should eq(1024)
      end
    end
  end
end
