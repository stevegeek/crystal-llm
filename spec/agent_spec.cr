require "./spec_helper"
require "../src/crystal_llm/agent"
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

# The system-message content of an agent's built Chat (or nil if none).
private def system_content(agent : CrystalLLM::Agent) : String | CrystalLLM::Content | Nil
  agent.chat.messages.find(&.role.system?).try(&.content)
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
end
