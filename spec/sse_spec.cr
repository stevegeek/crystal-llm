require "./spec_helper"
require "../src/crystal_llm/sse"

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
