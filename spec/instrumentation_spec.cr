require "./spec_helper"

# Ports the instrumentation behaviour (ruby_llm's Instrumentation module +
# instrument_completion / execute_tool instrumentation). No live network: a fully
# in-process fake provider drives canned responses.

# Records every (name, payload) the instrumenter observes, capturing payload keys
# after the wrapped block has attached its result-side keys.
class RecordingInstrumenter < CrystalLLM::Instrumenter
  getter events : Array({String, CrystalLLM::Instrumentation::Payload})

  def initialize
    @events = [] of {String, CrystalLLM::Instrumentation::Payload}
  end

  def instrument(name : String, payload : CrystalLLM::Instrumentation::Payload,
                 &block : CrystalLLM::Instrumentation::Payload -> T) : T forall T
    result = block.call(payload)
    @events << {name, payload}
    result
  end

  def event(name : String) : CrystalLLM::Instrumentation::Payload?
    @events.find { |(n, _)| n == name }.try(&.[1])
  end
end

class InstrumentationFakeProvider < CrystalLLM::Provider
  class_property scripted : Array(CrystalLLM::Message) = [] of CrystalLLM::Message

  def self.reset! : Nil
    self.scripted = [] of CrystalLLM::Message
  end

  def self.configuration_requirements : Array(String)
    [] of String
  end

  def complete(messages : Array(CrystalLLM::Message),
               tools : Hash(String, CrystalLLM::Tool),
               temperature : Float64?, model : CrystalLLM::Model::Info,
               params : Hash(String, JSON::Any) = {} of String => JSON::Any,
               headers : Hash(String, String) = {} of String => String,
               schema : JSON::Any? = nil,
               thinking : CrystalLLM::Thinking::Config? = nil,
               tool_prefs : Hash(String, String?)? = nil) : CrystalLLM::Message
    next_scripted
  end

  def complete(messages : Array(CrystalLLM::Message),
               tools : Hash(String, CrystalLLM::Tool),
               temperature : Float64?, model : CrystalLLM::Model::Info,
               params : Hash(String, JSON::Any) = {} of String => JSON::Any,
               headers : Hash(String, String) = {} of String => String,
               schema : JSON::Any? = nil,
               thinking : CrystalLLM::Thinking::Config? = nil,
               tool_prefs : Hash(String, String?)? = nil,
               &block : CrystalLLM::Chunk ->) : CrystalLLM::Message
    message = next_scripted
    text = message.content
    block.call(CrystalLLM::Chunk.new(role: CrystalLLM::Role::Assistant,
      content: text.is_a?(String) ? text : nil))
    message
  end

  private def next_scripted : CrystalLLM::Message
    raise "InstrumentationFakeProvider ran out of scripted responses" if self.class.scripted.empty?
    self.class.scripted.shift
  end
end

CrystalLLM::Provider.register("instrumentation_fake", InstrumentationFakeProvider)

class InstrumentationEchoTool < CrystalLLM::Tool
  description "Echoes the supplied word"
  param word : String, "the word to echo", required: true # ameba:disable Lint/UselessAssign

  def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
    "echo: #{args["word"].as_s}"
  end
end

private def instrumentation_assistant(text : String) : CrystalLLM::Message
  CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: text,
    input_tokens: 11, output_tokens: 7)
end

private def instrumentation_tool_call_message(id : String, name : String,
                                              args : Hash(String, JSON::Any)) : CrystalLLM::Message
  calls = {id => CrystalLLM::ToolCall.new(id: id, name: name, arguments: args)}
  CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, tool_calls: calls)
end

private def new_instrumentation_chat : CrystalLLM::Chat
  CrystalLLM::Chat.new(model: "fake-model", provider: "instrumentation_fake",
    assume_model_exists: true)
end

# Fetches a recorded event by name, failing the example with a clear message if it
# was never emitted (avoids `not_nil!` and gives a useful failure when absent).
private def fetch_event(recorder : RecordingInstrumenter,
                        name : String) : CrystalLLM::Instrumentation::Payload
  recorder.event(name) || fail("expected a #{name.inspect} event to have been emitted")
end

describe CrystalLLM::Instrumentation do
  before_each do
    InstrumentationFakeProvider.reset!
    CrystalLLM.config.instrumenter = nil
  end

  after_each do
    CrystalLLM.config.instrumenter = nil
  end

  describe "no instrumenter configured (default no-op)" do
    it "is a transparent no-op: complete returns the response unchanged" do
      CrystalLLM.config.instrumenter.should be_nil
      InstrumentationFakeProvider.scripted = [instrumentation_assistant("hi there")]
      chat = new_instrumentation_chat

      response = chat.ask("hello")

      response.content.should eq("hi there")
      chat.messages.size.should eq(2)
    end

    it "Instrumentation.instrument just yields the payload when no instrumenter" do
      payload = CrystalLLM::Instrumentation::Payload.new
      payload["model"] = "x"
      ran = false
      result = CrystalLLM::Instrumentation.instrument("evt.crystal_llm", payload) do |event|
        ran = true
        event.should be(payload)
        42
      end
      ran.should be_true
      result.should eq(42)
    end
  end

  describe "chat.crystal_llm event" do
    it "emits a chat event with the request + response payload keys" do
      recorder = RecordingInstrumenter.new
      CrystalLLM.config.instrumenter = recorder
      InstrumentationFakeProvider.scripted = [instrumentation_assistant("hi there")]
      chat = new_instrumentation_chat

      response = chat.ask("hello")
      response.content.should eq("hi there")

      event = fetch_event(recorder, "chat.crystal_llm")

      # Request-side keys.
      event["chat"].as(CrystalLLM::Chat).should be(chat)
      event["provider"].should eq("instrumentationfakeprovider")
      event["model"].should eq("fake-model")
      event["message_count"].should eq(1) # only the user message at request time
      event["streaming"].should eq(false)
      event.has_key?("tools").should be_true
      event.has_key?("temperature").should be_true
      event.has_key?("schema").should be_true
      event.has_key?("thinking").should be_true

      # Response-side keys attached by the block.
      event["response"].as(CrystalLLM::Message).should be(response)
      event["response_role"].should eq("Assistant")
      event["tool_call"].should eq(false)
      event["input_tokens"].should eq(11)
      event["output_tokens"].should eq(7)
      event.has_key?("cached_tokens").should be_true
      event.has_key?("thinking_tokens").should be_true
      event["messages_after"].as(Array(CrystalLLM::Message)).size.should eq(2)
    end

    it "marks streaming completions as streaming: true" do
      recorder = RecordingInstrumenter.new
      CrystalLLM.config.instrumenter = recorder
      InstrumentationFakeProvider.scripted = [instrumentation_assistant("streamed")]
      chat = new_instrumentation_chat

      chat.ask("hello") { |_chunk| }

      event = fetch_event(recorder, "chat.crystal_llm")
      event["streaming"].should eq(true)
    end
  end

  describe "tool_call.crystal_llm event" do
    it "emits a tool_call event per tool invocation with result keys" do
      recorder = RecordingInstrumenter.new
      CrystalLLM.config.instrumenter = recorder
      args = {"word" => JSON::Any.new("ping")}
      InstrumentationFakeProvider.scripted = [
        instrumentation_tool_call_message("call_1", "instrumentation_echo", args),
        instrumentation_assistant("done"),
      ]
      chat = new_instrumentation_chat.with_tool(InstrumentationEchoTool.new)

      chat.ask("call the tool").content.should eq("done")

      event = fetch_event(recorder, "tool_call.crystal_llm")

      event["tool_name"].should eq("instrumentation_echo")
      event["tool_call_id"].should eq("call_1")
      event["provider"].should eq("instrumentationfakeprovider")
      event["model"].should eq("fake-model")
      event.has_key?("tool").should be_true
      event.has_key?("tool_call").should be_true
      event.has_key?("tool_arguments").should be_true
      event["result"].as(String).should eq("echo: ping")
      event["result_content"].as(String).should eq("echo: ping")
    end

    it "does not emit a tool_call event for an unavailable tool" do
      recorder = RecordingInstrumenter.new
      CrystalLLM.config.instrumenter = recorder
      args = {"word" => JSON::Any.new("ping")}
      InstrumentationFakeProvider.scripted = [
        instrumentation_tool_call_message("call_1", "missing_tool", args),
        instrumentation_assistant("recovered"),
      ]
      chat = new_instrumentation_chat # no tools registered

      chat.ask("call missing").content.should eq("recovered")

      recorder.event("tool_call.crystal_llm").should be_nil
      recorder.event("chat.crystal_llm").should_not be_nil
    end
  end

  describe "CrystalLLM.instrument facade" do
    it "delegates through the configured instrumenter and returns the block value" do
      recorder = RecordingInstrumenter.new
      CrystalLLM.config.instrumenter = recorder
      payload = CrystalLLM::Instrumentation::Payload.new
      payload["model"] = "m"

      result = CrystalLLM.instrument("custom.crystal_llm", payload) do |event|
        event["extra"] = "added"
        99
      end

      result.should eq(99)
      event = fetch_event(recorder, "custom.crystal_llm")
      event["extra"].should eq("added")
    end
  end

  describe "ProcInstrumenter" do
    it "runs the work and invokes the callback with the final payload" do
      seen = [] of String
      CrystalLLM.config.instrumenter = CrystalLLM::ProcInstrumenter.new do |name, payload|
        seen << "#{name}:#{payload["model"]?}"
      end
      InstrumentationFakeProvider.scripted = [instrumentation_assistant("ok")]
      chat = new_instrumentation_chat

      chat.ask("hi").content.should eq("ok")
      seen.should contain("chat.crystal_llm:fake-model")
    end
  end
end
