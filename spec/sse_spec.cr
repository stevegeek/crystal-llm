require "./spec_helper"
require "../src/crystal_llm/sse"
require "../src/crystal_llm"
require "./support/stub_connection"

# REGRESSION (BUG 2, streaming.cr): the SSE loop fed every parsed `data:` frame to
# `build_chunk`, even when the parsed JSON was NOT an object (e.g. `data: true`, a
# bare number/string/array). ruby_llm's streaming.rb only does
# `build_chunk(data) if data.is_a?(Hash)`. A non-object frame must be skipped (no
# chunk), while an object frame still yields exactly one chunk.
private def openai_stream_provider : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "test"
  CrystalLLM::Providers::OpenAI.new(config)
end

describe "CrystalLLM::Streaming non-object frame handling" do
  it "yields NO chunk for a non-object frame and one chunk for an object frame" do
    provider = openai_stream_provider
    stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
    provider.connection = stub

    # First frame is a bare `true` (non-object); second is a real OpenAI delta.
    stub.stub_stream(
      "data: true\n\n" \
      "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
    )

    chunks = [] of CrystalLLM::Chunk
    provider.stream_response("{}") { |chunk| chunks << chunk }

    chunks.size.should eq(1) # only the object frame produced a chunk
    chunks.first.content.try(&.to_s).should eq("hi")
  end

  it "ignores a frame whose JSON is a bare array (still non-object)" do
    provider = openai_stream_provider
    stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
    provider.connection = stub

    stub.stub_stream("data: [1,2,3]\n\n")

    chunks = [] of CrystalLLM::Chunk
    provider.stream_response("{}") { |chunk| chunks << chunk }

    chunks.should be_empty
  end
end

describe CrystalLLM::SSE do
  it "parses a simple data event" do
    events = [] of {String, String}
    sse = CrystalLLM::SSE.new
    sse.feed("data: hello\n\n") { |type, data| events << {type, data} }
    events.should eq([{"message", "hello"}])
  end

  it "accumulates multi-line data and honours event types" do
    events = [] of {String, String}
    sse = CrystalLLM::SSE.new
    sse.feed("event: ping\ndata: a\ndata: b\n\n") { |type, data| events << {type, data} }
    events.should eq([{"ping", "a\nb"}])
  end

  it "tolerates chunk boundaries mid-line" do
    events = [] of {String, String}
    sse = CrystalLLM::SSE.new
    sse.feed("data: hel") { |type, data| events << {type, data} }
    sse.feed("lo\n\n") { |type, data| events << {type, data} }
    events.should eq([{"message", "hello"}])
  end

  it "ignores comment lines and tolerates CRLF" do
    events = [] of {String, String}
    sse = CrystalLLM::SSE.new
    sse.feed(": keep-alive\r\ndata: [DONE]\r\n\r\n") { |type, data| events << {type, data} }
    events.should eq([{"message", "[DONE]"}])
  end

  it "emits multiple events from one stream" do
    events = [] of {String, String}
    sse = CrystalLLM::SSE.new
    sse.feed("data: one\n\ndata: two\n\n") { |type, data| events << {type, data} }
    events.should eq([{"message", "one"}, {"message", "two"}])
  end
end
