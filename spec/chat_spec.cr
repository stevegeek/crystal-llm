require "./spec_helper"
require "../src/crystal_llm/chat"

# A fully in-process fake provider. It overrides `complete` directly (both the
# sync and streaming overloads) so NO HTTP is performed — the canned responses
# are driven by a class-level script the spec sets up per test.
class ChatSpecFakeProvider < CrystalLLM::Provider
  # Queue of canned assistant Messages, consumed FIFO on each `complete`.
  class_property scripted : Array(CrystalLLM::Message) = [] of CrystalLLM::Message
  # Records each batch of messages the chat passed in (to assert accumulation).
  class_property seen_messages : Array(Array(CrystalLLM::Message)) = [] of Array(CrystalLLM::Message)
  class_property last_temperature : Float64? = nil
  # Records the tool_prefs passed on each `complete` call (to assert the chat
  # threads its tool-choice state and resets a forced choice between turns).
  class_property seen_tool_prefs : Array(Hash(String, String?)?) = [] of Hash(String, String?)?

  def self.reset! : Nil
    self.scripted = [] of CrystalLLM::Message
    self.seen_messages = [] of Array(CrystalLLM::Message)
    self.last_temperature = nil
    self.seen_tool_prefs = [] of Hash(String, String?)?
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
    self.class.seen_messages << messages.dup
    self.class.last_temperature = temperature
    self.class.seen_tool_prefs << tool_prefs.try(&.dup)
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
    self.class.seen_messages << messages.dup
    self.class.seen_tool_prefs << tool_prefs.try(&.dup)
    message = next_scripted
    # Emit one chunk carrying the message's text so streaming callers see data.
    text = message.content
    block.call(CrystalLLM::Chunk.new(role: CrystalLLM::Role::Assistant,
      content: text.is_a?(String) ? text : nil))
    message
  end

  private def next_scripted : CrystalLLM::Message
    raise "ChatSpecFakeProvider ran out of scripted responses" if self.class.scripted.empty?
    self.class.scripted.shift
  end
end

CrystalLLM::Provider.register("chat_spec_fake", ChatSpecFakeProvider)

# A trivial tool used to exercise the tool-call loop offline.
class ChatSpecEchoTool < CrystalLLM::Tool
  description "Echoes the supplied word"
  param word : String, "the word to echo", required: true # ameba:disable Lint/UselessAssign

  def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
    "echo: #{args["word"].as_s}"
  end
end

private def assistant(text : String) : CrystalLLM::Message
  CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: text)
end

private def tool_call_message(id : String, name : String,
                              args : Hash(String, JSON::Any)) : CrystalLLM::Message
  calls = {id => CrystalLLM::ToolCall.new(id: id, name: name, arguments: args)}
  CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, tool_calls: calls)
end

private def new_chat : CrystalLLM::Chat
  # gpt-5.4 is the configured default_model and resolves to the openai provider;
  # but we want the fake provider, so we construct against a known fake model.
  CrystalLLM::Chat.new(model: "fake-model", provider: "chat_spec_fake",
    assume_model_exists: true)
end

describe CrystalLLM::Chat do
  before_each do
    ChatSpecFakeProvider.reset!
  end

  describe "#ask" do
    it "adds a user message and returns the assistant response" do
      ChatSpecFakeProvider.scripted = [assistant("hi there")]
      chat = new_chat

      response = chat.ask("hello")

      response.role.should eq(CrystalLLM::Role::Assistant)
      response.content.should eq("hi there")
      # user message + assistant response accumulated
      chat.messages.size.should eq(2)
      chat.messages.first.role.should eq(CrystalLLM::Role::User)
      chat.messages.first.content.should eq("hello")
      chat.messages.last.content.should eq("hi there")
    end

    it "is aliased as say" do
      ChatSpecFakeProvider.scripted = [assistant("said")]
      chat = new_chat
      chat.say("speak").content.should eq("said")
    end
  end

  describe "streaming #ask" do
    it "yields chunks and returns the final message" do
      ChatSpecFakeProvider.scripted = [assistant("streamed")]
      chat = new_chat
      chunks = [] of String

      response = chat.ask("hello") do |chunk|
        c = chunk.content
        chunks << c if c.is_a?(String)
      end

      response.content.should eq("streamed")
      chunks.should eq(["streamed"])
    end
  end

  describe "tool calls" do
    it "executes a tool then completes again with the result" do
      args = {"word" => JSON::Any.new("crystal")} of String => JSON::Any
      ChatSpecFakeProvider.scripted = [
        tool_call_message("call_1", "chat_spec_echo", args),
        assistant("done"),
      ]
      chat = new_chat.with_tool(ChatSpecEchoTool.new)

      response = chat.ask("use the tool")

      response.content.should eq("done")
      # user, assistant(tool_call), tool result, assistant(done)
      chat.messages.size.should eq(4)
      tool_message = chat.messages[2]
      tool_message.role.should eq(CrystalLLM::Role::Tool)
      tool_message.content.should eq("echo: crystal")
      tool_message.tool_call_id.should eq("call_1")
    end

    it "reports an error for an unknown tool" do
      args = {} of String => JSON::Any
      ChatSpecFakeProvider.scripted = [
        tool_call_message("call_x", "nonexistent", args),
        assistant("recovered"),
      ]
      chat = new_chat

      response = chat.ask("call missing tool")

      response.content.should eq("recovered")
      tool_message = chat.messages[2]
      tool_message.role.should eq(CrystalLLM::Role::Tool)
      tool_message.content.as(String).should contain("unavailable tool")
    end

    it "forwards tool_prefs to the provider on each completion" do
      ChatSpecFakeProvider.scripted = [assistant("ok")]
      chat = new_chat.with_tool(ChatSpecEchoTool.new, choice: "auto", calls: "many")

      chat.ask("hi")

      ChatSpecFakeProvider.seen_tool_prefs.size.should eq(1)
      prefs = ChatSpecFakeProvider.seen_tool_prefs.first.as(Hash(String, String?))
      prefs["choice"].should eq("auto")
      prefs["calls"].should eq("many")
    end

    it "resets a forced tool choice after the forced call (per-turn :calls limit)" do
      # First completion is FORCED to call the tool (choice == tool name); after
      # the tool runs, forced_tool_choice? triggers reset_tool_choice, so the
      # follow-up completion sees choice == nil.
      args = {"word" => JSON::Any.new("crystal")} of String => JSON::Any
      ChatSpecFakeProvider.scripted = [
        tool_call_message("call_1", "chat_spec_echo", args),
        assistant("done"),
      ]
      chat = new_chat.with_tool(ChatSpecEchoTool.new, choice: "chat_spec_echo")

      chat.ask("use the tool")

      ChatSpecFakeProvider.seen_tool_prefs.size.should eq(2)
      first = ChatSpecFakeProvider.seen_tool_prefs[0].as(Hash(String, String?))
      second = ChatSpecFakeProvider.seen_tool_prefs[1].as(Hash(String, String?))
      first["choice"].should eq("chat_spec_echo")
      # forced choice was reset before the second completion
      second["choice"].should be_nil
    end
  end

  describe "callbacks" do
    it "runs after_message callbacks with each new message" do
      ChatSpecFakeProvider.scripted = [assistant("cb")]
      seen = [] of CrystalLLM::Message
      chat = new_chat.after_message { |msg| seen << msg }

      chat.ask("hi")

      seen.map(&.content).should eq(["cb"])
    end
  end

  describe "#with_temperature" do
    it "threads the temperature into the provider call" do
      ChatSpecFakeProvider.scripted = [assistant("ok")]
      chat = new_chat.with_temperature(0.2)

      chat.ask("hi")

      ChatSpecFakeProvider.last_temperature.should eq(0.2)
    end
  end

  describe "#with_instructions" do
    it "prepends a system message" do
      ChatSpecFakeProvider.scripted = [assistant("ok")]
      chat = new_chat.with_instructions("be terse")

      chat.messages.size.should eq(1)
      chat.messages.first.role.should eq(CrystalLLM::Role::System)
      chat.messages.first.content.should eq("be terse")

      chat.ask("hi")
      # system message stays first
      chat.messages.first.role.should eq(CrystalLLM::Role::System)
    end

    it "replaces by default and appends with append: true" do
      chat = new_chat
        .with_instructions("first")
        .with_instructions("second")
      chat.messages.count(&.role.system?).should eq(1)
      chat.messages.first.content.should eq("second")

      chat.with_instructions("third", append: true)
      chat.messages.count(&.role.system?).should eq(2)
    end
  end

  describe "#with_schema" do
    it "normalizes a raw json-schema into the envelope" do
      raw = {
        "name"   => JSON::Any.new("person"),
        "schema" => JSON::Any.new({
          "type" => JSON::Any.new("object"),
        } of String => JSON::Any),
      } of String => JSON::Any
      chat = new_chat.with_schema(raw)

      envelope = chat.schema
      envelope.should_not be_nil
      schema = envelope.as(JSON::Any).as_h
      schema["name"].as_s.should eq("person")
      schema["strict"].as_bool.should be_true
      schema["schema"].as_h["type"].as_s.should eq("object")
    end

    it "accepts a CrystalLLM::Schema instance" do
      chat = new_chat.with_schema(ChatSpecPersonSchema.new("person"))
      envelope = chat.schema
      envelope.should_not be_nil
      schema = envelope.as(JSON::Any).as_h
      schema["name"].as_s.should eq("person")
      schema["schema"].as_h["properties"].as_h.has_key?("name").should be_true
    end

    # Regression (BUG 11): a non-object JSON::Any schema (e.g. a bare array) was
    # silently `as_h?`-dropped to nil, leaving @schema unset. It must now raise
    # rather than swallow the caller's malformed schema.
    it "raises (not silently nils) for a non-object JSON::Any schema" do
      chat = new_chat
      expect_raises(ArgumentError, "requires a JSON object schema") do
        chat.with_schema(JSON.parse(%([1, 2, 3])))
      end
    end

    it "accepts a valid JSON::Any object schema" do
      chat = new_chat.with_schema(JSON.parse(%({"name":"person","schema":{"type":"object"}})))
      chat.schema.should_not be_nil
      chat.schema.as(JSON::Any).as_h["name"].as_s.should eq("person")
    end
  end

  describe "typed structured output (#with_schema(T) / #ask_as)" do
    it "derives a JSON schema from a struct type's instance vars" do
      chat = new_chat.with_schema(ChatSpecWeather)

      envelope = chat.schema.as(JSON::Any).as_h
      envelope["name"].as_s.should eq("ChatSpecWeather")
      schema = envelope["schema"].as_h
      props = schema["properties"].as_h
      props["location"].as_h["type"].as_s.should eq("string")
      props["temperature"].as_h["type"].as_s.should eq("integer")
      props["raining"].as_h["type"].as_s.should eq("boolean")
      # nilable Float64 mapped to a number and renamed via @[JSON::Field(key:)]
      props["wind_speed"].as_h["type"].as_s.should eq("number")
      # array of strings
      props["alerts"].as_h["type"].as_s.should eq("array")
      props["alerts"].as_h["items"].as_h["type"].as_s.should eq("string")

      required = schema["required"].as_a.map(&.as_s)
      # non-nilable fields are required; the nilable `wind_speed` is NOT
      required.should contain("location")
      required.should contain("temperature")
      required.should contain("raining")
      required.should contain("alerts")
      required.should_not contain("wind_speed")
    end

    it "ask_as deserializes the assistant response into the typed struct" do
      json = {
        "location"    => "Berlin",
        "temperature" => 17,
        "raining"     => true,
        "wind_speed"  => 4.5,
        "alerts"      => ["wind"],
      }.to_json
      ChatSpecFakeProvider.scripted = [assistant(json)]
      chat = new_chat

      result = chat.ask_as("weather in Berlin?", ChatSpecWeather)

      result.should be_a(ChatSpecWeather)
      result.location.should eq("Berlin")
      result.temperature.should eq(17)
      result.raining.should be_true
      result.wind.should eq(4.5)
      result.alerts.should eq(["wind"])
      # the schema was set on the chat as a side effect
      chat.schema.should_not be_nil
    end

    it "ask_as tolerates an absent nilable field" do
      json = {
        "location"    => "Mars",
        "temperature" => -60,
        "raining"     => false,
        "alerts"      => [] of String,
      }.to_json
      ChatSpecFakeProvider.scripted = [assistant(json)]
      chat = new_chat

      result = chat.ask_as("weather on Mars?", ChatSpecWeather)
      result.wind.should be_nil
      result.alerts.should be_empty
    end
  end

  describe "legacy single-slot callbacks" do
    it "on_new_message fires when a message is added (aliases before_message)" do
      ChatSpecFakeProvider.scripted = [assistant("hi")]
      seen = [] of CrystalLLM::Message
      # silence the deprecation warning for the test
      CrystalLLM.config.deprecation_behavior = "silence"
      chat = new_chat.on_new_message { |msg| seen << msg }

      chat.ask("hello")

      # before_message fires once before the assistant response in the sync path
      seen.size.should be >= 1
    ensure
      CrystalLLM.config.deprecation_behavior = "warn"
    end

    it "on_end_message fires after each new message (aliases after_message)" do
      ChatSpecFakeProvider.scripted = [assistant("done")]
      seen = [] of CrystalLLM::Message
      CrystalLLM.config.deprecation_behavior = "silence"
      chat = new_chat.on_end_message { |msg| seen << msg }

      chat.ask("hi")

      seen.map(&.content).should contain("done")
    ensure
      CrystalLLM.config.deprecation_behavior = "warn"
    end

    it "raises the deprecation when behavior is 'raise'" do
      CrystalLLM.config.deprecation_behavior = "raise"
      chat = new_chat
      expect_raises(CrystalLLM::DeprecationError, "on_new_message") do
        chat.on_new_message { |_msg| }
      end
    ensure
      CrystalLLM.config.deprecation_behavior = "warn"
    end

    it "on_tool_call and on_tool_result fire around tool execution" do
      CrystalLLM.config.deprecation_behavior = "silence"
      args = {"word" => JSON::Any.new("crystal")} of String => JSON::Any
      ChatSpecFakeProvider.scripted = [
        tool_call_message("call_1", "chat_spec_echo", args),
        assistant("done"),
      ]
      calls = [] of String
      results = [] of String
      chat = new_chat
        .with_tool(ChatSpecEchoTool.new)
        .on_tool_call { |tool_call| calls << tool_call.name }
        .on_tool_result { |result| results << (result.is_a?(String) ? result : result.to_s) }

      chat.ask("use the tool")

      calls.should eq(["chat_spec_echo"])
      results.should eq(["echo: crystal"])
    ensure
      CrystalLLM.config.deprecation_behavior = "warn"
    end
  end

  describe "#ask content building" do
    # Regression (BUG 10): when message AND attachments are both nil, ruby_llm
    # builds Content.new(nil, nil), which raises ArgumentError ("both nil"). The
    # port previously returned nil, swallowing the error.
    it "raises ArgumentError when both message and attachments are nil" do
      chat = new_chat
      expect_raises(ArgumentError, "both nil") do
        chat.ask(nil)
      end
    end
  end

  describe "Enumerable" do
    it "iterates over messages" do
      ChatSpecFakeProvider.scripted = [assistant("a")]
      chat = new_chat
      chat.ask("q")
      roles = chat.map(&.role)
      roles.should eq([CrystalLLM::Role::User, CrystalLLM::Role::Assistant])
    end
  end

  describe "#reset_messages!" do
    it "clears accumulated messages" do
      ChatSpecFakeProvider.scripted = [assistant("a")]
      chat = new_chat
      chat.ask("q")
      chat.messages.empty?.should be_false
      chat.reset_messages!
      chat.messages.empty?.should be_true
    end
  end

  # Parity quick win: Chat#cost aggregates Cost over the message list
  # (ruby_llm's `Cost.aggregate(messages.map(&:cost))`).
  describe "#cost" do
    it "aggregates the per-message costs" do
      ChatSpecFakeProvider.scripted = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "hi",
          input_tokens: 10, output_tokens: 5),
      ]
      chat = new_chat
      chat.ask("hello")

      cost = chat.cost
      cost.should be_a(CrystalLLM::Cost)
      # The model is `assume_model_exists` (no pricing), so token amounts have no
      # price and `total` is nil — but the aggregate is still produced.
      cost.tokens?.should be_true
    end
  end
end

class ChatSpecPersonSchema < CrystalLLM::Schema
  string "name", description: "Full name"
end

# A JSON::Serializable struct used to exercise the typed `ask_as(T)` /
# `with_schema(T)` hatch: a mix of String / Int / Bool / nilable / Array fields
# plus a renamed key to verify the derived schema honors @[JSON::Field].
struct ChatSpecWeather
  include JSON::Serializable

  getter location : String
  getter temperature : Int32
  getter raining : Bool

  @[JSON::Field(key: "wind_speed")]
  getter wind : Float64?

  getter alerts : Array(String)

  def initialize(@location, @temperature, @raining, @wind, @alerts)
  end
end
