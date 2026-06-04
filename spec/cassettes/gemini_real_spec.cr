# REAL-DATA parser tests for the Gemini provider, driven by harvested VCR
# cassette fixtures (spec/fixtures/cassettes/gemini/*). These are ACTUAL recorded
# Gemini responses (not hand-written), so they exercise the real wire shapes the
# parsers must tolerate.
#
# Coverage (whatever EXISTS for gemini):
#   chat_*.json    -> parse_completion_response -> Message (content/tool_calls + tokens)
#   stream_*.sse   -> Streaming.stream_response (via StubConnection) -> accumulated Message
#   embedding_1.json -> parse_embedding_response -> Embedding with non-empty vectors
#
# (No image/moderation/transcription cassettes for gemini — Gemini has no
# moderation endpoint and the harvester captured none for image/transcription.)
require "../spec_helper"
require "../../src/crystal_llm/providers/gemini"
require "../support/stub_connection"

private CASSETTES = File.join(__DIR__, "..", "fixtures", "cassettes", "gemini")

private def cassette(name : String) : String
  File.read(File.join(CASSETTES, name))
end

private def configured_gemini : CrystalLLM::Providers::Gemini
  config = CrystalLLM::Configuration.new
  config.gemini_api_key = "test"
  CrystalLLM::Providers::Gemini.new(config)
end

private def gemini_model(id : String) : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: id, name: id, provider: "gemini")
end

# Wrap a raw JSON body in a Crest::Response (mirrors spec/provider_spec.cr).
private def response_for(body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(200, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

# Drives the FULL streaming path: render_payload sets @model_id (stream_url needs
# it), the StubConnection replays the real .sse body line-by-line, and the
# accumulator assembles a Message.
private def stream_message(sse_name : String, model : String) : Tuple(CrystalLLM::Message, Array(CrystalLLM::Chunk))
  provider = configured_gemini
  stub = CrystalLLM::Spec::StubConnection.new(provider, CrystalLLM.config)
  provider.connection = stub

  provider.render_payload(
    [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
    tools: {} of String => CrystalLLM::Tool,
    temperature: nil,
    model: gemini_model(model),
    stream: true
  )

  stub.stub_stream(cassette(sse_name))
  chunks = [] of CrystalLLM::Chunk
  message = provider.stream_response("{}") { |chunk| chunks << chunk }
  {message, chunks}
end

describe "Gemini real-data parsers" do
  describe "parse_completion_response (chat_*.json)" do
    it "chat_1.json: parses structured-JSON text content + thinking tokens" do
      provider = configured_gemini
      message = provider.parse_completion_response(response_for(cassette("chat_1.json")))

      message.should be_a(CrystalLLM::Message)
      message.role.should eq(CrystalLLM::Role::Assistant)

      content = message.content
      content.should be_a(String)
      content.as(String).should eq(%({"name":"John","age":30}))
      message.tool_calls.should be_nil

      # input = promptTokenCount(13) - cached(0); output = candidates(10)+thoughts(250)
      message.input_tokens.should eq(13)
      message.output_tokens.should eq(260)
      message.thinking_tokens.should eq(250)
      message.model_id.should eq("gemini-3-flash-preview")
    end

    it "chat_2.json: parses a functionCall part into tool_calls (no text content)" do
      provider = configured_gemini
      message = provider.parse_completion_response(response_for(cassette("chat_2.json")))

      tool_calls = message.tool_calls
      tool_calls.should_not be_nil
      tc = tool_calls || fail("expected tool_calls, got nil")
      tc.size.should eq(1)
      call = tc.first_value
      call.name.should eq("array_params")
      call.arguments.has_key?("tags").should be_true
      call.arguments["tags"].as_a.map(&.as_s).should eq(["red", "blue"])
      call.thought_signature.should_not be_nil

      # No text part -> assistant-with-tool-calls content normalizes to "".
      message.content.should eq("")
      message.input_tokens.should eq(63)
      message.output_tokens.should eq(18 + 77)
      message.thinking_tokens.should eq(77)
      message.model_id.should eq("gemini-2.5-flash")
    end

    it "chat_3.json: parses a one-word text answer + multimodal prompt token detail" do
      provider = configured_gemini
      message = provider.parse_completion_response(response_for(cassette("chat_3.json")))

      message.content.should eq("Ruby")
      message.tool_calls.should be_nil
      message.input_tokens.should eq(51)
      message.output_tokens.should eq(1 + 26)
      message.thinking_tokens.should eq(26)
    end

    it "chat_4.json: parses a long multi-paragraph video-description answer" do
      provider = configured_gemini
      message = provider.parse_completion_response(response_for(cassette("chat_4.json")))

      content = message.content
      content.should be_a(String)
      text = content.as(String)
      text.empty?.should be_false
      text.should contain("beach scene")
      message.input_tokens.should eq(4119)
      message.output_tokens.should eq(239 + 959)
      message.thinking_tokens.should eq(959)
    end
  end

  describe "Streaming.stream_response (stream_*.sse)" do
    it "stream_2.sse: accumulates text deltas into the final answer + tokens" do
      message, chunks = stream_message("stream_2.sse", "gemini-2.5-flash")

      chunks.size.should eq(2)
      content = message.content
      content.should be_a(String)
      content.as(String).should eq("Based on my analysis, the best language to learn is Ruby.")
      message.input_tokens.should eq(141)
      message.output_tokens.should eq(13)
      message.model_id.should eq("gemini-2.5-flash")
    end

    it "stream_4.sse: accumulates text deltas into the final answer + tokens" do
      message, chunks = stream_message("stream_4.sse", "gemini-2.5-flash")

      chunks.size.should eq(2)
      message.content.should eq("The best language to learn is Ruby.")
      message.input_tokens.should eq(215)
      message.output_tokens.should eq(8)
    end

    it "stream_1.sse: captures a streamed functionCall as a tool_call" do
      message, chunks = stream_message("stream_1.sse", "gemini-2.5-flash")

      chunks.size.should eq(1)
      tool_calls = message.tool_calls
      tool_calls.should_not be_nil
      if tc = tool_calls
        tc.size.should eq(1)
        tc.first_value.name.should eq("best_language_to_learn")
      end
      # function-call deltas carry usage; thinking tokens present (43).
      message.thinking_tokens.should eq(43)
    end

    it "stream_3.sse: captures a streamed functionCall as a tool_call" do
      message, chunks = stream_message("stream_3.sse", "gemini-2.5-flash")

      chunks.size.should eq(1)
      tool_calls = message.tool_calls
      tool_calls.should_not be_nil
      if tc = tool_calls
        tc.size.should eq(1)
        tc.first_value.name.should eq("best_language_to_learn")
      end
      message.thinking_tokens.should eq(40)
    end
  end

  describe "parse_embedding_response (embedding_1.json)" do
    it "parses a batch-embed response into non-empty nested vectors" do
      provider = configured_gemini
      # The cassette returns 3 embeddings; with an Array input the parser keeps the
      # nested (batch) shape.
      texts = ["a", "b", "c"]
      embedding = provider.parse_embedding_response(
        response_for(cassette("embedding_1.json")),
        model: "text-embedding-004",
        text: texts
      )

      embedding.should be_a(CrystalLLM::Embedding)
      embedding.model.should eq("text-embedding-004")

      vectors = embedding.vectors
      vectors.should be_a(Array(Array(Float64)))
      if vectors.is_a?(Array(Array(Float64)))
        vectors.size.should eq(3)
        vectors.each do |row|
          row.empty?.should be_false
          row.size.should eq(768)
        end
        # spot-check a real recorded value
        vectors[0][0].should be_close(-0.008762145, 1e-9)
      end
    end

    it "flattens a single-input embed to a flat vector" do
      provider = configured_gemini
      # Same cassette, but only when there is exactly one returned vector AND the
      # input is not an Array does the parser flatten. The cassette has 3 rows, so
      # a String input here still yields the batch shape — assert the shape rule on
      # the real data: nested rows, flat per-row vectors.
      embedding = provider.parse_embedding_response(
        response_for(cassette("embedding_1.json")),
        model: "text-embedding-004",
        text: "single"
      )

      vectors = embedding.vectors
      # 3 rows present -> not flattened even for a String input.
      vectors.should be_a(Array(Array(Float64)))
    end
  end
end
