require "./spec_helper"
require "../src/crystal_llm/chat"
require "../src/crystal_llm/connection"

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

# A second registered fake provider, used by the `#with_model` swap test to prove
# the provider is re-resolved (not just the model id) mid-conversation.
class ChatSpecFakeProviderTwo < ChatSpecFakeProvider
end

CrystalLLM::Provider.register("chat_spec_fake_two", ChatSpecFakeProviderTwo)

# ---- Header-precedence (DIVERGENCE 16) harness -----------------------------
#
# A provider that exposes a colliding auth header, plus a Connection subclass that
# records the result of the REAL (inherited, private) `merge_headers` WITHOUT doing
# any HTTP. This drives a caller header through the connection's merge and proves
# the provider/auth header wins on a key collision.
class ChatSpecHeaderProvider < CrystalLLM::Provider
  def self.configuration_requirements : Array(String)
    [] of String
  end

  def api_base : String
    "http://127.0.0.1:0"
  end

  def headers : Hash(String, String)
    {"Authorization" => "Bearer provider-secret", "X-Provider" => "yes"}
  end
end

class ChatSpecHeaderProbeConnection < CrystalLLM::Connection
  # Records the merged headers (caller merged UNDER provider headers) for each call.
  # `merge_headers` is an inherited private method — a subclass may call it with no
  # explicit receiver, so this exercises the production precedence logic directly.
  getter merged : Array(Hash(String, String)) = [] of Hash(String, String)

  def record(headers : Hash(String, String)) : Hash(String, String)
    result = merge_headers(headers)
    @merged << result
    result
  end
end

# A trivial tool used to exercise the tool-call loop offline.
class ChatSpecEchoTool < CrystalLLM::Tool
  description "Echoes the supplied word"
  param word : String, "the word to echo", required: true # ameba:disable Lint/UselessAssign

  def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
    "echo: #{args["word"].as_s}"
  end
end

# A tool that halts the conversation (returns a Tool::Halt), used to assert the
# loop stops WITHOUT a follow-up completion.
class ChatSpecHaltingTool < CrystalLLM::Tool
  description "Halts the conversation"

  def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
    halt("stopped here")
  end
end

# A tool that records how many instances run concurrently. Under the fibers-only
# concurrency mode, two of these overlap (each yields at `sleep`), so
# `max_running` reaches 2. `delay` staggers completion so the on_result callback
# order (completion order) is deterministic.
class ChatSpecProbeTool < CrystalLLM::Tool
  description "Records concurrent execution"
  param label : String, "the label to echo back", required: true              # ameba:disable Lint/UselessAssign
  param delay : Float64, "seconds to sleep before finishing", required: false # ameba:disable Lint/UselessAssign

  class_property running : Int32 = 0
  class_property max_running : Int32 = 0

  def self.reset! : Nil
    self.running = 0
    self.max_running = 0
  end

  def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
    self.class.running += 1
    self.class.max_running = self.class.running if self.class.running > self.class.max_running
    seconds = args["delay"]?.try(&.as_f?) || 0.01
    sleep seconds.seconds
    "finished #{args["label"].as_s}"
  ensure
    self.class.running -= 1
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

      response = chat.ask("hello").as(CrystalLLM::Message)

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
      chat.say("speak").as(CrystalLLM::Message).content.should eq("said")
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
      end.as(CrystalLLM::Message)

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

      response = chat.ask("use the tool").as(CrystalLLM::Message)

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

      # #7: after_tool_result (the additive form aliased by on_tool_result) fires
      # with the synthesized error payload when the model calls an unregistered tool.
      seen_results = [] of CrystalLLM::ToolResult
      chat.after_tool_result { |result| seen_results << result }

      response = chat.ask("call missing tool").as(CrystalLLM::Message)

      response.content.should eq("recovered")
      tool_message = chat.messages[2]
      tool_message.role.should eq(CrystalLLM::Role::Tool)
      tool_message.content.as(String).should contain("unavailable tool")

      # the callback observed the error result (a `{ "error" => ... }` Hash payload)
      seen_results.size.should eq(1)
      error_result = seen_results.first
      error_hash = error_result.as(Hash(String, JSON::Any))
      error_hash["error"].as_s.should contain("unavailable tool `nonexistent`")
    end

    # #6: a tool that halts returns the Tool::Halt itself (NOT a follow-up
    # completion), and the halt content is still appended as a tool-role message.
    it "returns Tool::Halt without a second completion when a tool halts" do
      args = {} of String => JSON::Any
      # ONLY a single scripted response: the tool_call. There is deliberately NO
      # follow-up assistant message — if the loop tried to re-complete it would
      # raise "ran out of scripted responses".
      ChatSpecFakeProvider.scripted = [
        tool_call_message("call_h", "chat_spec_halting", args),
      ]
      chat = new_chat.with_tool(ChatSpecHaltingTool.new)

      result = chat.ask("halt please")

      # the return value is the Tool::Halt sentinel, not a Message
      result.should be_a(CrystalLLM::Tool::Halt)
      result.as(CrystalLLM::Tool::Halt).content.should eq("stopped here")

      # exactly ONE completion ran (no follow-up)
      ChatSpecFakeProvider.seen_messages.size.should eq(1)

      # the halt content was appended as a tool-role message
      # (user, assistant(tool_call), tool result)
      chat.messages.size.should eq(3)
      tool_message = chat.messages.last
      tool_message.role.should eq(CrystalLLM::Role::Tool)
      tool_message.content.should eq("stopped here")
      tool_message.tool_call_id.should eq("call_h")
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

  describe "tool concurrency preferences" do
    it "defaults to sequential (nil concurrency)" do
      new_chat.concurrency.should be_nil
    end

    it "stores concurrency: true as the fibers mode (Crystal divergence from :threads)" do
      new_chat.with_tools(concurrency: true).concurrency.should eq("fibers")
    end

    it "accepts the explicit fibers mode string" do
      new_chat.with_tools(concurrency: "fibers").concurrency.should eq("fibers")
    end

    it "clears concurrency with false" do
      chat = new_chat.with_tools(concurrency: true)
      chat.with_tools(concurrency: false).concurrency.should be_nil
    end

    it "treats a blank/whitespace concurrency string as disabled" do
      # Carry-over from Task 2: the non-nilable Bool|String config option can't get
      # the config DSL's blank-string-to-nil treatment, so normalize handles it here.
      new_chat.with_tools(concurrency: "  ").concurrency.should be_nil
    end

    it "raises for threads (the Ruby-only mode) naming the available modes" do
      expect_raises(ArgumentError, /Unknown tool concurrency.*fibers/) do
        new_chat.with_tools(concurrency: "threads")
      end
    end

    it "raises for an unknown concurrency mode" do
      expect_raises(ArgumentError, /Unknown tool concurrency/) do
        new_chat.with_tools(concurrency: "warp_speed")
      end
    end

    it "uses the configured tool concurrency by default" do
      original = CrystalLLM.config.tool_concurrency
      CrystalLLM.config.tool_concurrency = true
      new_chat.concurrency.should eq("fibers")
    ensure
      CrystalLLM.config.tool_concurrency = original || false
    end

    it "lets a chat override the configured tool concurrency" do
      original = CrystalLLM.config.tool_concurrency
      CrystalLLM.config.tool_concurrency = true
      new_chat.with_tools(concurrency: false).concurrency.should be_nil
    ensure
      CrystalLLM.config.tool_concurrency = original || false
    end
  end

  describe "concurrent tool execution" do
    before_each { ChatSpecProbeTool.reset! }

    it "executes multiple tool calls concurrently, appending results in completion order" do
      probe = ChatSpecProbeTool.new
      tool_calls = {
        "call_1" => CrystalLLM::ToolCall.new(id: "call_1", name: probe.name,
          arguments: {"label" => JSON::Any.new("slow"), "delay" => JSON::Any.new(0.05)}),
        "call_2" => CrystalLLM::ToolCall.new(id: "call_2", name: probe.name,
          arguments: {"label" => JSON::Any.new("fast"), "delay" => JSON::Any.new(0.01)}),
      }
      ChatSpecFakeProvider.scripted = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, tool_calls: tool_calls),
        assistant("done"),
      ]
      chat = new_chat.with_tool(probe, concurrency: true)

      response = chat.ask("run the tools").as(CrystalLLM::Message)

      response.content.should eq("done")
      chat.concurrency.should eq("fibers")
      # Both probes overlapped.
      ChatSpecProbeTool.max_running.should eq(2)

      tool_messages = chat.messages.select(&.role.tool?)
      # Results are appended as each finishes: the fast call (call_2) lands first.
      tool_messages.map(&.tool_call_id).should eq(["call_2", "call_1"])
      tool_messages.map(&.content).should eq(["finished fast", "finished slow"])
      # user, assistant(tool_calls), 2 tool results, assistant(done)
      chat.messages.size.should eq(5)
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

    # Code change 3: derive_typed_schema RECURSES into nested JSON::Serializable
    # structs (a nested property AND an array-of-structs), instead of degrading a
    # nested struct to an unconstrained `{"type":"object"}`.
    it "derives a nested object schema for a 2-level-nested struct" do
      chat = new_chat.with_schema(ChatSpecCity)

      schema = chat.schema.as(JSON::Any).as_h["schema"].as_h
      props = schema["properties"].as_h
      props["name"].as_h["type"].as_s.should eq("string")

      # nested struct property -> nested object schema (NOT a bare object)
      geo = props["geo"].as_h
      geo["type"].as_s.should eq("object")
      geo_props = geo["properties"].as_h
      # honors @[JSON::Field(key: "lat")] inside the nested struct
      geo_props["lat"].as_h["type"].as_s.should eq("number")
      geo_props["longitude"].as_h["type"].as_s.should eq("number")
      geo["required"].as_a.map(&.as_s).should eq(["lat", "longitude"])

      # array-of-structs property -> array with a nested-object `items` schema
      landmarks = props["landmarks"].as_h
      landmarks["type"].as_s.should eq("array")
      items = landmarks["items"].as_h
      items["type"].as_s.should eq("object")
      items["properties"].as_h.has_key?("lat").should be_true

      # nilable nested-or-scalar still tracks required-ness at the parent level
      required = schema["required"].as_a.map(&.as_s)
      required.should contain("name")
      required.should contain("geo")
      required.should contain("landmarks")
      required.should_not contain("nickname")
    end
  end

  # Code change 1: a schema-constrained ask returns PARSED data (Content::Raw),
  # not a raw JSON String (ruby_llm parity — `response.content = JSON.parse(...)`).
  describe "structured-output response normalization" do
    it "replaces a valid-JSON schema response with parsed Content::Raw data" do
      schema = {
        "name"   => JSON::Any.new("person"),
        "schema" => JSON::Any.new({"type" => JSON::Any.new("object")} of String => JSON::Any),
      } of String => JSON::Any
      ChatSpecFakeProvider.scripted = [assistant(%({"name":"Ada","age":36}))]
      chat = new_chat.with_schema(schema)

      response = chat.ask("who?").as(CrystalLLM::Message)

      content = response.content
      content.should be_a(CrystalLLM::Content::Raw)
      parsed = content.as(CrystalLLM::Content::Raw).value
      parsed["name"].as_s.should eq("Ada")
      parsed["age"].as_i.should eq(36)
    end

    it "leaves the content a String when the schema response is not valid JSON" do
      schema = {"schema" => JSON::Any.new({"type" => JSON::Any.new("object")} of String => JSON::Any)} of String => JSON::Any
      ChatSpecFakeProvider.scripted = [assistant("not json at all")]
      chat = new_chat.with_schema(schema)

      response = chat.ask("who?").as(CrystalLLM::Message)
      response.content.should eq("not json at all")
    end

    # Code change 1 + regression #3: with a schema set AND a tool-call in the loop,
    # the intermediate tool-call message content must NOT be JSON-parsed (the
    # `return if response.tool_call?` guard) — only the FINAL answer is parsed.
    it "does not parse an intermediate tool-call message when a schema is set" do
      args = {"word" => JSON::Any.new("crystal")} of String => JSON::Any
      schema = {"schema" => JSON::Any.new({"type" => JSON::Any.new("object")} of String => JSON::Any)} of String => JSON::Any
      ChatSpecFakeProvider.scripted = [
        tool_call_message("call_1", "chat_spec_echo", args),
        assistant(%({"answer":"done"})),
      ]
      chat = new_chat.with_tool(ChatSpecEchoTool.new).with_schema(schema)

      response = chat.ask("use the tool").as(CrystalLLM::Message)

      # user, assistant(tool_call), tool result, assistant(final JSON)
      chat.messages.size.should eq(4)

      # the assistant tool-call message kept intact content (NOT a Content::Raw)
      tool_call_msg = chat.messages[1]
      tool_call_msg.tool_call?.should be_true
      tool_call_msg.content.should_not be_a(CrystalLLM::Content::Raw)

      # the tool-role result message content is the intact String, never parsed
      tool_msg = chat.messages[2]
      tool_msg.role.should eq(CrystalLLM::Role::Tool)
      tool_msg.content.should eq("echo: crystal")

      # only the FINAL answer was parsed into structured data
      response.content.should be_a(CrystalLLM::Content::Raw)
      response.content.as(CrystalLLM::Content::Raw).value["answer"].as_s.should eq("done")
    end
  end

  # Code change 2: with_schema(nil) clears a previously-set schema mid-conversation.
  describe "#with_schema(nil)" do
    it "clears a previously-set schema" do
      schema = {"schema" => JSON::Any.new({"type" => JSON::Any.new("object")} of String => JSON::Any)} of String => JSON::Any
      chat = new_chat.with_schema(schema)
      chat.schema.should_not be_nil

      chat.with_schema(nil)
      chat.schema.should be_nil
    end

    it "stops normalizing responses once the schema is cleared" do
      schema = {"schema" => JSON::Any.new({"type" => JSON::Any.new("object")} of String => JSON::Any)} of String => JSON::Any
      ChatSpecFakeProvider.scripted = [assistant(%({"k":1}))]
      chat = new_chat.with_schema(schema).with_schema(nil)

      response = chat.ask("hi").as(CrystalLLM::Message)
      # no schema -> no normalization -> content stays the raw String
      response.content.should eq(%({"k":1}))
    end
  end

  # Test addition #1: header precedence (DIVERGENCE 16 — provider/auth headers win
  # over caller-supplied headers of the same name; a caller must not clobber auth).
  describe "header precedence (DIVERGENCE 16)" do
    it "keeps the provider header when a caller header has the same name" do
      provider = ChatSpecHeaderProvider.new(CrystalLLM.config)
      conn = ChatSpecHeaderProbeConnection.new(provider, CrystalLLM.config)

      # The caller tries to override Authorization (and adds an unrelated header).
      caller_headers = {
        "Authorization" => "Bearer attacker-override",
        "X-Caller"      => "present",
      }

      merged = conn.record(caller_headers)

      # the provider's Authorization survives (NOT clobbered by the caller's value)
      merged["Authorization"].should eq("Bearer provider-secret")
      merged["X-Provider"].should eq("yes")
      # an unrelated caller header is still carried through
      merged["X-Caller"].should eq("present")
      conn.merged.size.should eq(1)
    end
  end

  # Test addition #2: with_tools(replace: true) clears the existing tool set.
  describe "#with_tools(replace:)" do
    it "replaces the existing tool set when replace: true" do
      chat = new_chat.with_tool(ChatSpecHaltingTool.new)
      chat.tools.keys.should contain("chat_spec_halting")

      chat.with_tools(ChatSpecEchoTool.new, replace: true)
      chat.tools.keys.should eq(["chat_spec_echo"])
    end

    it "clears all tools when replace: true with a nil tool" do
      chat = new_chat.with_tool(ChatSpecEchoTool.new)
      chat.tools.empty?.should be_false

      chat.with_tools(nil, replace: true)
      chat.tools.empty?.should be_true
    end
  end

  # Test addition #4: with_model swaps the PROVIDER (not just the model id)
  # mid-conversation. Provider B (ChatSpecFakeProviderTwo) records its own calls.
  describe "#with_model provider swap" do
    it "routes the next completion through the newly-resolved provider" do
      ChatSpecFakeProviderTwo.reset!
      ChatSpecFakeProvider.scripted = [assistant("from A")]
      ChatSpecFakeProviderTwo.scripted = [assistant("from B")]

      chat = new_chat
      first = chat.ask("hi A").as(CrystalLLM::Message)
      first.content.should eq("from A")
      # provider A saw one completion, provider B none yet
      ChatSpecFakeProvider.seen_messages.size.should eq(1)
      ChatSpecFakeProviderTwo.seen_messages.size.should eq(0)

      chat.with_model("fake-model-two", provider: "chat_spec_fake_two", assume_exists: true)
      second = chat.ask("hi B").as(CrystalLLM::Message)
      second.content.should eq("from B")

      # the second completion went through provider B (B recorded it; A did not run again)
      ChatSpecFakeProviderTwo.seen_messages.size.should eq(1)
      ChatSpecFakeProvider.seen_messages.size.should eq(1)
    ensure
      ChatSpecFakeProviderTwo.reset!
    end
  end

  # Test addition #5: additive callbacks (plus legacy aliases) fire in REGISTRATION
  # order around a completion.
  describe "additive callback ordering" do
    it "fires before/after message callbacks in registration order" do
      ChatSpecFakeProvider.scripted = [assistant("answer")]
      CrystalLLM.config.deprecation_behavior = "silence"
      order = [] of String

      chat = new_chat
        .before_message { |_m| order << "before_1" }
        .before_message { |_m| order << "before_2" }
        .on_new_message { |_m| order << "before_legacy" } # aliases before_message
        .after_message { |_m| order << "after_1" }
        .after_message { |_m| order << "after_2" }
        .on_end_message { |_m| order << "after_legacy" } # aliases after_message

      chat.ask("hi")

      # the before_* group fires (in registration order) before the after_* group
      before = order.select(&.starts_with?("before"))
      after = order.select(&.starts_with?("after"))
      before.should eq(["before_1", "before_2", "before_legacy"])
      after.should eq(["after_1", "after_2", "after_legacy"])
      # every before_* precedes every after_*
      order.index!("before_legacy").should be < order.index!("after_1")
    ensure
      CrystalLLM.config.deprecation_behavior = "warn"
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

    # ruby_llm e70d4ef8 (Fixes #773): a message that streamed without resolvable
    # model info (no `model_id`, so `Message#model_info` is nil) falls back to the
    # CHAT's model for pricing, instead of producing a nil cost. Mirrors
    # `Cost.aggregate(messages.map { |m| m.cost(model: m.model_info || model) })`.
    it "uses the chat model for cost when a message has no resolvable model info" do
      priced_model = CrystalLLM::Model::Info.new(JSON.parse({
        "id"       => "chat-cost-fallback-model",
        "name"     => "Chat Cost Fallback Model",
        "provider" => "chat_spec_fake",
        "pricing"  => {
          "text_tokens" => {
            "standard" => {
              "input_per_million"  => 1.0,
              "output_per_million" => 2.0,
            },
          },
        },
      }.to_json).as_h)
      unless CrystalLLM::Models.instance.all.any?(&.id.== "chat-cost-fallback-model")
        CrystalLLM::Models.instance.all << priced_model
      end

      chat = CrystalLLM::Chat.new(model: "chat-cost-fallback-model", provider: "chat_spec_fake")
      # Added directly (bypassing the provider), so `model_id` is nil and
      # `model_info` cannot resolve — this is the "streamed without model info" case.
      message = CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "Hi",
        input_tokens: 1_000, output_tokens: 2_000)
      message.model_info.should be_nil
      chat.add_message(message)

      cost = chat.cost.total
      cost.should_not be_nil
      cost.as(Float64).should be_close(0.005, 0.0000000001)
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

# 2-level-nested JSON::Serializable graph to exercise the RECURSIVE
# `derive_typed_schema` (a nested struct property AND an array-of-structs property
# both produce nested object schemas rather than degrading to `{"type":"object"}`).
struct ChatSpecGeo
  include JSON::Serializable

  @[JSON::Field(key: "lat")]
  getter latitude : Float64
  getter longitude : Float64

  def initialize(@latitude, @longitude)
  end
end

struct ChatSpecCity
  include JSON::Serializable

  getter name : String
  getter geo : ChatSpecGeo
  getter landmarks : Array(ChatSpecGeo)
  getter nickname : String?

  def initialize(@name, @geo, @landmarks, @nickname)
  end
end
