# REAL-DATA parser tests for the Azure provider, driven by harvested VCR cassette
# fixtures (actual recorded provider output, not hand-written). These exercise the
# OpenAI-compatible parse path that Azure inherits (parse_completion_response,
# build_chunk via the streaming accumulator, parse_embedding_response) against
# real-world response shapes.
#
# Fixtures: spec/fixtures/cassettes/azure/{chat_N.json,stream_N.sse,embedding_N.json}
#
# Some chat fixtures are base64-encoded by the harvester (VCR encodes bodies that
# contain non-ASCII — e.g. a literal emoji in the assistant content). We detect that
# and decode before feeding the parser, since the wire body the provider sees is the
# decoded JSON.
require "../spec_helper"
require "../support/stub_connection"
require "base64"

private FIXTURE_DIR = File.join(__DIR__, "..", "fixtures", "cassettes", "azure")

# Reads a cassette body, transparently base64-decoding JSON bodies the harvester
# encoded (it base64-encodes bodies containing non-ASCII; decoded JSON starts with
# '{'/'['). SSE bodies (.sse) are always raw text and pass through untouched.
private def read_cassette(name : String) : String
  raw = File.read(File.join(FIXTURE_DIR, name))
  return raw if name.ends_with?(".sse")

  raw = raw.strip
  return raw if raw.starts_with?('{') || raw.starts_with?('[')
  Base64.decode_string(raw)
end

private def azure_provider : CrystalLLM::Providers::Azure
  config = CrystalLLM::Configuration.new
  config.azure_api_base = "https://example.openai.azure.com/openai/deployments/test"
  config.azure_api_key = "test"
  CrystalLLM::Providers::Azure.new(config)
end

private def response_for(body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(200, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

# Drives a real SSE body through the full streaming path: StubConnection replays the
# .sse text into post_stream, the Streaming mixin parses it with CrystalLLM::SSE and
# folds each build_chunk Chunk into the final Message.
private def stream_to_message(provider : CrystalLLM::Providers::Azure,
                              sse_name : String) : Tuple(CrystalLLM::Message, Array(CrystalLLM::Chunk))
  stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
  stub.stub_stream(read_cassette(sse_name))
  provider.connection = stub

  chunks = [] of CrystalLLM::Chunk
  message = provider.stream_response("{}") { |chunk| chunks << chunk }
  {message, chunks}
end

describe "Azure provider — real cassette data" do
  describe "parse_completion_response (chat_*.json)" do
    it "parses a plain text completion (chat_1)" do
      provider = azure_provider
      msg = provider.parse_completion_response(response_for(read_cassette("chat_1.json")))

      msg.should be_a(CrystalLLM::Message)
      msg.role.should eq(CrystalLLM::Role::Assistant)
      msg.content.should eq("Paris")
      msg.model_id.should eq("grok-4-1-fast-non-reasoning")
      # token counts populated from real usage block
      msg.input_tokens.should eq(7)
      msg.output_tokens.should eq(1)
    end

    it "parses a tool-call completion (chat_2)" do
      provider = azure_provider
      msg = provider.parse_completion_response(response_for(read_cassette("chat_2.json")))

      msg.tool_call?.should be_true
      calls = msg.tool_calls
      calls.should_not be_nil
      raise "no tool_calls" unless calls
      calls.size.should eq(1)

      call = calls["call_67489799"]?
      call.should_not be_nil
      raise "missing expected tool call id" unless call
      call.name.should eq("content_returning")
      # arguments parsed from the stringified JSON on the wire
      call.arguments["query"]?.try(&.as_s).should eq("test data")

      msg.input_tokens.should eq(211)
      msg.output_tokens.should eq(27)
    end

    it "parses a unicode/multimodal completion (chat_3, base64-encoded fixture)" do
      provider = azure_provider
      msg = provider.parse_completion_response(response_for(read_cassette("chat_3.json")))

      content = msg.content
      content.should be_a(String)
      raise "expected string content" unless content.is_a?(String)
      content.should contain("Processed: test data")
      content.should contain("\u{1F48E}") # the 💎 emoji survives decode + parse

      # prompt_tokens 510 = text_tokens 254 + image_tokens 256, cached 0, no cache write.
      # input_tokens = prompt - cache_read - cache_write = 510 - 0 - 0
      msg.input_tokens.should eq(510)
      msg.output_tokens.should eq(13)
    end

    it "parses a numeric-answer completion (chat_4)" do
      provider = azure_provider
      msg = provider.parse_completion_response(response_for(read_cassette("chat_4.json")))
      msg.content.should eq("4")
      msg.input_tokens.should eq(7)
      msg.output_tokens.should eq(1)
    end
  end

  describe "streaming (stream_*.sse) via Streaming.stream_response" do
    it "accumulates content deltas into a Message (stream_1)" do
      provider = azure_provider
      message, chunks = stream_to_message(provider, "stream_1.sse")

      chunks.empty?.should be_false
      # "1" "," " " "2" "," " " "3" "." -> "1, 2, 3."
      message.content.should eq("1, 2, 3.")
      message.model_id.should eq("grok-4-1-fast-non-reasoning")
      # usage arrives on the final (choices: []) event
      message.input_tokens.should eq(7)
      message.output_tokens.should eq(8)
    end

    it "captures a streamed tool call (stream_2)" do
      provider = azure_provider
      message, chunks = stream_to_message(provider, "stream_2.sse")

      chunks.empty?.should be_false
      message.tool_call?.should be_true
      calls = message.tool_calls
      raise "no tool_calls" unless calls
      calls.size.should eq(1)
      call = calls["call_08109836"]?
      raise "missing expected tool call id" unless call
      call.name.should eq("best_language_to_learn")

      message.input_tokens.should eq(205)
      message.output_tokens.should eq(18)
    end

    it "captures a streamed tool call (stream_4)" do
      provider = azure_provider
      message, _ = stream_to_message(provider, "stream_4.sse")

      message.tool_call?.should be_true
      calls = message.tool_calls
      raise "no tool_calls" unless calls
      call = calls["call_04519858"]?
      raise "missing expected tool call id" unless call
      call.name.should eq("best_language_to_learn")
      message.input_tokens.should eq(295)
      message.output_tokens.should eq(18)
    end

    it "builds chunks directly via SSE + build_chunk (stream_3)" do
      # Alternate driver: parse the SSE ourselves and call build_chunk per data event,
      # then accumulate. Validates build_chunk on a longer real stream.
      provider = azure_provider
      parser = CrystalLLM::SSE.new
      accumulator = CrystalLLM::StreamAccumulator.new
      chunk_count = 0

      read_cassette("stream_3.sse").each_line do |line|
        parser.feed("#{line}\n") do |_type, data|
          next if data == "[DONE]"
          json = JSON.parse(data) rescue next
          chunk = provider.build_chunk(json)
          accumulator.add(chunk)
          chunk_count += 1
        end
      end

      chunk_count.should be > 0
      message = accumulator.to_message(nil)
      content = message.content
      content.should be_a(String)
      raise "expected string content" unless content.is_a?(String)
      content.empty?.should be_false
      message.model_id.should eq("grok-4-1-fast-non-reasoning")
    end
  end

  describe "parse_embedding_response (embedding_*.json)" do
    it "parses a single embedding into a flat vector (embedding_1)" do
      provider = azure_provider
      resp = response_for(read_cassette("embedding_1.json"))
      embedding = provider.parse_embedding_response(resp, "embed-english-v3.0", "hello")

      embedding.should be_a(CrystalLLM::Embedding)
      embedding.model.should eq("embed-english-v3.0")
      # single (non-Array) input -> flat Array(Float64)
      vectors = embedding.vectors
      vectors.should be_a(Array(Float64))
      raise "expected flat vector" unless vectors.is_a?(Array(Float64))
      vectors.size.should eq(1024)
      vectors.any? { |v| v != 0.0 }.should be_true
      embedding.input_tokens.should eq(3)
    end
  end
end
