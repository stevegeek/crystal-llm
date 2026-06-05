require "./spec_helper"

# Ports ruby_llm spec/ruby_llm/message_spec.rb (@ 1.15.0).
# Content-normalization, token aliases, and `#cost` (parity quick win) are ported.
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

  describe "#thinking" do
    it "is nil when no thinking is provided" do
      CrystalLLM::Message.new(role: :assistant, content: "hi").thinking.should be_nil
    end

    it "exposes a Thinking value passed via the thinking: kwarg" do
      thinking = CrystalLLM::Thinking.new(text: "reasoning", signature: "sig")
      message = CrystalLLM::Message.new(role: :assistant, content: "hi", thinking: thinking)
      message.thinking.should_not be_nil
      message.thinking.try(&.text).should eq("reasoning")
      message.thinking.try(&.signature).should eq("sig")
    end
  end

  describe "#to_h" do
    it "includes thinking text + signature and drops nils" do
      thinking = CrystalLLM::Thinking.new(text: "because", signature: "sig-1")
      message = CrystalLLM::Message.new(
        role: :assistant, content: "answer", thinking: thinking,
        input_tokens: 3, output_tokens: 4
      )
      h = message.to_h
      h[:role].should eq(CrystalLLM::Role::Assistant)
      h[:content].should eq("answer")
      h[:thinking].should eq("because")
      h[:thinking_signature].should eq("sig-1")
      h[:input_tokens].should eq(3)
      h[:output_tokens].should eq(4)
      # tool_call_id is nil → omitted (compact)
      h.has_key?(:tool_call_id).should be_false
    end

    it "omits thinking keys when there is no thinking" do
      h = CrystalLLM::Message.new(role: :user, content: "hi").to_h
      h.has_key?(:thinking).should be_false
      h.has_key?(:thinking_signature).should be_false
    end
  end

  # Parity quick win: Message#cost (mirrors ruby_llm's
  # `cost(model:) = Cost.new(tokens:, model: model || model_info)`).
  describe "#cost" do
    it "builds a Cost over the message tokens and an explicit model" do
      model = CrystalLLM::Model::Info.new(JSON.parse({
        "id"       => "priced",
        "name"     => "Priced",
        "provider" => "openai",
        "pricing"  => {
          "text_tokens" => {
            "standard" => {
              "input_per_million"  => 1.0,
              "output_per_million" => 2.0,
            },
          },
        },
      }.to_json).as_h)

      message = CrystalLLM::Message.new(role: :assistant, content: "hi",
        input_tokens: 1_000_000, output_tokens: 1_000_000)

      cost = message.cost(model: model)
      cost.should be_a(CrystalLLM::Cost)
      cost.input.should eq(1.0)
      cost.output.should eq(2.0)
    end

    it "falls back to nil model when model_id is unset (no pricing)" do
      message = CrystalLLM::Message.new(role: :assistant, content: "hi",
        input_tokens: 5, output_tokens: 5)
      message.model_info.should be_nil
      # tokens present, but no model → no price → input amount is nil.
      message.cost.input.should be_nil
    end
  end
end

describe CrystalLLM::Chunk do
  it "is a Message" do
    CrystalLLM::Chunk.new(role: :assistant, content: "partial").should be_a(CrystalLLM::Message)
  end
end
