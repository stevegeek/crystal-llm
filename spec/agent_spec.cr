require "./spec_helper"
require "../src/crystal_llm/agent"

# An in-process fake provider so an Agent's delegated `ask`/block/`each`/`complete`
# surface (BUG 7) can be exercised offline (no network). Overrides both `complete`
# overloads.
class AgentSpecFakeProvider < CrystalLLM::Provider
  class_property scripted : Array(CrystalLLM::Message) = [] of CrystalLLM::Message
  # Captured on the last `complete` call so tests can assert the Agent applied
  # `thinking`/`headers`/`schema` to the Chat that drives this provider.
  class_property captured_thinking : CrystalLLM::Thinking::Config? = nil
  class_property captured_headers : Hash(String, String) = {} of String => String
  class_property captured_schema : JSON::Any? = nil

  def self.reset! : Nil
    self.scripted = [] of CrystalLLM::Message
    self.captured_thinking = nil
    self.captured_headers = {} of String => String
    self.captured_schema = nil
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
    self.class.captured_thinking = thinking
    self.class.captured_headers = headers
    self.class.captured_schema = schema
    self.class.scripted.shift
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
    message = self.class.scripted.shift
    text = message.content
    block.call(CrystalLLM::Chunk.new(role: CrystalLLM::Role::Assistant,
      content: text.is_a?(String) ? text : nil))
    message
  end
end

CrystalLLM::Provider.register("agent_spec_fake", AgentSpecFakeProvider)

# Seed the model registry with a fake-provider model so an Agent (whose macro
# builds `CrystalLLM.chat(model: ...)` against the registry) resolves offline.
private def seed_agent_fake_model : Nil
  return if CrystalLLM::Models.instance.all.any?(&.id.== "agent-fake-model")
  info = CrystalLLM::Model::Info.new(JSON.parse({
    "id"       => "agent-fake-model",
    "name"     => "Agent Fake",
    "provider" => "agent_spec_fake",
    "type"     => "chat",
  }.to_json).as_h)
  CrystalLLM::Models.instance.all << info
end

private class FakeProviderAgent < CrystalLLM::Agent
  model "agent-fake-model"
end

# Agent builds a Chat, which resolves the model against the registry and
# instantiates the OpenAI provider. The provider self-registers (and adds its
# `openai_api_key` config option) only when its file is required; spec_helper's
# `crystal_llm` require does not pull in providers. No network: Agent.new only
# constructs the Chat + applies config — `ask` (the network path) is never called.
require "../src/crystal_llm/providers/openai"

# A static agent: model + static instructions + a static tool.
private class WeatherTool < CrystalLLM::Tool
  description "Look up the weather"

  def execute : CrystalLLM::ToolResult
    "sunny"
  end
end

private class StaticAgent < CrystalLLM::Agent
  model "gpt-4o"
  instructions "You are a helpful assistant."
  tools WeatherTool.new
  temperature 0.2
end

# A context agent: a typed `input` resolved inside an `instructions` block.
private class GreeterAgent < CrystalLLM::Agent
  model "gpt-4o"
  input user : String # ameba:disable Lint/UselessAssign
  instructions { |ctx| "hi #{ctx.user}" }
end

# A schema used by the macro tests.
private class PersonSchema < CrystalLLM::Schema
  string "name"
  integer "age"
end

# An agent applying the new class macros: headers / schema / thinking.
private class ConfiguredAgent < CrystalLLM::Agent
  model "agent-fake-model"
  headers({"X-Trace" => "abc"})
  schema PersonSchema.new("person")
  thinking effort: "high"
end

# A ctx-block schema resolved against a typed input.
private class DynamicSchemaAgent < CrystalLLM::Agent
  model "agent-fake-model"
  input person_name : String # ameba:disable Lint/UselessAssign
  schema { |ctx| PersonSchema.new(ctx.person_name) }
end

# The system-message content of an agent's built Chat (or nil if none).
private def system_content(agent : CrystalLLM::Agent) : String | CrystalLLM::Content | Nil
  agent.chat.messages.find(&.role.system?).try(&.content)
end

# The normalized schema envelope an agent applied to its Chat. Fails the spec
# (rather than `not_nil!`-ing) if no schema was applied.
private def chat_schema(agent : CrystalLLM::Agent) : JSON::Any
  agent.chat.schema || fail "expected the agent to apply a schema, got nil"
end

describe CrystalLLM::Agent do
  before_each { CrystalLLM.config.openai_api_key = "test" }
  after_each { CrystalLLM.config.openai_api_key = nil }

  describe "a static agent" do
    it "builds a Chat with the configured model" do
      agent = StaticAgent.new
      agent.chat.should be_a(CrystalLLM::Chat)
      agent.chat.model.id.should eq("gpt-4o")
    end

    it "applies the static instructions as a system message" do
      system_content(StaticAgent.new).should eq("You are a helpful assistant.")
    end

    it "applies the static tools" do
      agent = StaticAgent.new
      agent.chat.tools.keys.should contain("weather")
      agent.chat.tools["weather"].should be_a(WeatherTool)
    end

    it "applies the temperature" do
      # temperature is private chat state; assert via the class-level reader.
      StaticAgent.temperature.should eq(0.2)
    end
  end

  describe "a context agent" do
    it "resolves the instructions block against a passed input" do
      system_content(GreeterAgent.new(user: "Sam")).should eq("hi Sam")
    end

    it "resolves a different input independently per instance" do
      system_content(GreeterAgent.new(user: "Ada")).should eq("hi Ada")
      system_content(GreeterAgent.new(user: "Lin")).should eq("hi Lin")
    end
  end

  describe "headers / schema / thinking class macros" do
    before_each { seed_agent_fake_model; AgentSpecFakeProvider.reset! }

    it "applies static headers to the built Chat" do
      ConfiguredAgent.new.chat.headers.should eq({"X-Trace" => "abc"})
    end

    it "applies a static schema to the built Chat" do
      schema = chat_schema(ConfiguredAgent.new)
      schema["name"].as_s.should eq("person")
      props = schema["schema"]["properties"].as_h
      props.keys.should contain("name")
      props.keys.should contain("age")
    end

    it "applies thinking to the built Chat (observed via the provider)" do
      AgentSpecFakeProvider.scripted = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "ok"),
      ]
      ConfiguredAgent.new.ask("q")
      captured = AgentSpecFakeProvider.captured_thinking
      (captured || fail "expected thinking to be applied").effort.should eq("high")
    end
  end

  describe "a ctx-block schema" do
    before_each { seed_agent_fake_model }

    it "resolves the schema block against a passed input" do
      chat_schema(DynamicSchemaAgent.new(person_name: "Ada"))["name"].as_s.should eq("Ada")
    end

    it "resolves a different input independently per instance" do
      chat_schema(DynamicSchemaAgent.new(person_name: "Lin"))["name"].as_s.should eq("Lin")
      chat_schema(DynamicSchemaAgent.new(person_name: "Sam"))["name"].as_s.should eq("Sam")
    end
  end

  # Regression (BUG 7): `method_missing` cannot forward a passed block or the
  # `with:` attachment kwarg, so explicit `ask`/`say`/`each`/`complete` overloads
  # delegate them to `@chat`. Without the overloads these calls fail to compile.
  describe "block / attachment / each delegation" do
    before_each { seed_agent_fake_model; AgentSpecFakeProvider.reset! }

    it "forwards a streaming block through ask to @chat" do
      AgentSpecFakeProvider.scripted = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "streamed"),
      ]
      agent = FakeProviderAgent.new
      chunks = [] of String

      response = agent.ask("hello") do |chunk|
        c = chunk.content
        chunks << c if c.is_a?(String)
      end

      response.content.should eq("streamed")
      chunks.should eq(["streamed"])
    end

    it "forwards a streaming block through say to @chat" do
      AgentSpecFakeProvider.scripted = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "said"),
      ]
      agent = FakeProviderAgent.new
      seen = [] of String
      agent.say("speak") { |chunk| (c = chunk.content).is_a?(String) && (seen << c) }
      seen.should eq(["said"])
    end

    it "delegates each over the chat's messages" do
      AgentSpecFakeProvider.scripted = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "a"),
      ]
      agent = FakeProviderAgent.new
      agent.ask("q")
      roles = [] of CrystalLLM::Role
      agent.each { |message| roles << message.role }
      roles.should eq([CrystalLLM::Role::User, CrystalLLM::Role::Assistant])
    end

    it "delegates a streaming complete to @chat" do
      AgentSpecFakeProvider.scripted = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "done"),
      ]
      agent = FakeProviderAgent.new
      agent.ask("seed-without-streaming-second-call")
      AgentSpecFakeProvider.scripted = [
        CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: "done"),
      ]
      got = [] of String
      agent.complete { |chunk| (c = chunk.content).is_a?(String) && (got << c) }
      got.should eq(["done"])
    end
  end
end
