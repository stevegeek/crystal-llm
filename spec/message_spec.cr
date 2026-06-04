require "./spec_helper"

# Ports ruby_llm spec/ruby_llm/message_spec.rb (@ 1.15.0).
# The `#cost` cases are deferred until model/info + cost + the models registry land
# (tracked in PORTING.md); content-normalization and token aliases are ported here.
describe CrystalLLM::Message do
  describe "#content" do
    it "normalizes nil content to empty string for assistant tool-call messages" do
      tool_call = CrystalLLM::ToolCall.new(id: "call_1", name: "weather")
      message = CrystalLLM::Message.new(
        role: :assistant, content: nil, tool_calls: {"call_1" => tool_call}
      )
      message.content.should eq("")
    end

    it "keeps nil content for messages without tool calls" do
      message = CrystalLLM::Message.new(role: :assistant, content: nil, tool_calls: nil)
      message.content.should be_nil
    end

    it "unwraps a plain text message back to a String" do
      CrystalLLM::Message.new(role: :user, content: "Hello").content.should eq("Hello")
    end
  end

  describe "cache token aliases" do
    it "exposes cache_read_tokens and cache_write_tokens" do
      message = CrystalLLM::Message.new(
        role: :assistant, content: "Hello", cached_tokens: 42, cache_creation_tokens: 7
      )
      message.cache_read_tokens.should eq(42)
      message.cache_write_tokens.should eq(7)
      message.tokens.try(&.cache_read).should eq(42)
      message.tokens.try(&.cache_write).should eq(7)
    end
  end

  describe "roles" do
    it "accepts symbol, string, and enum roles" do
      CrystalLLM::Message.new(role: :user, content: "a").role.should eq(CrystalLLM::Role::User)
      CrystalLLM::Message.new(role: "assistant", content: "a").role.should eq(CrystalLLM::Role::Assistant)
      CrystalLLM::Message.new(role: CrystalLLM::Role::Tool, content: "a").role.should eq(CrystalLLM::Role::Tool)
    end

    it "raises InvalidRoleError for an unknown role" do
      expect_raises(CrystalLLM::InvalidRoleError) do
        CrystalLLM::Message.new(role: "wizard", content: "a")
      end
    end
  end

  describe "tool predicates" do
    it "detects tool calls and tool results" do
      tc = CrystalLLM::ToolCall.new(id: "c1", name: "weather")
      with_call = CrystalLLM::Message.new(role: :assistant, content: nil, tool_calls: {"c1" => tc})
      with_call.tool_call?.should be_true
      with_call.tool_result?.should be_false

      result = CrystalLLM::Message.new(role: :tool, content: "72F", tool_call_id: "c1")
      result.tool_result?.should be_true
      result.tool_results.should eq("72F")
    end
  end
end

describe CrystalLLM::Chunk do
  it "is a Message" do
    CrystalLLM::Chunk.new(role: :assistant, content: "partial").should be_a(CrystalLLM::Message)
  end
end
