require "./spec_helper"
require "../src/crystal_llm/stream_accumulator"

# Ports ruby_llm spec/ruby_llm/stream_accumulator_spec.rb (@ 1.15.0), plus
# coverage for the content/think-tag/token accumulation paths.
describe CrystalLLM::StreamAccumulator do
  describe "#add" do
    it "handles tool call deltas that omit arguments" do
      accumulator = CrystalLLM::StreamAccumulator.new
      tool_call = CrystalLLM::ToolCall.new(id: "call_1", name: "weather")
      chunk = CrystalLLM::Chunk.new(
        role: :assistant, content: nil, tool_calls: {"call_1" => tool_call}
      )

      accumulator.add(chunk)

      message = accumulator.to_message(nil)
      tool_calls = message.tool_calls.should_not be_nil
      tool_calls["call_1"].arguments.should eq({} of String => JSON::Any)
    end

    it "accumulates plain content across chunks" do
      accumulator = CrystalLLM::StreamAccumulator.new
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "Hello, "))
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "world!"))

      accumulator.content.should eq("Hello, world!")
      accumulator.to_message(nil).content.should eq("Hello, world!")
    end

    it "records the first non-nil model_id" do
      accumulator = CrystalLLM::StreamAccumulator.new
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "a", model_id: "gpt-x"))
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "b", model_id: "other"))

      accumulator.model_id.should eq("gpt-x")
    end

    it "folds token usage from chunks" do
      accumulator = CrystalLLM::StreamAccumulator.new
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "a", input_tokens: 10))
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "b", output_tokens: 5))

      tokens = accumulator.to_message(nil).tokens.should_not be_nil
      tokens.input.should eq(10)
      tokens.output.should eq(5)
    end
  end

  describe "<think> tag extraction" do
    it "splits inline think tags into content and thinking" do
      accumulator = CrystalLLM::StreamAccumulator.new
      accumulator.add(CrystalLLM::Chunk.new(
        role: :assistant, content: "before<think>reasoning</think>after"
      ))

      accumulator.content.should eq("beforeafter")
      accumulator.thinking.should_not be_nil
      accumulator.thinking.try(&.text).should eq("reasoning")
    end

    it "handles a think tag that straddles chunk boundaries" do
      accumulator = CrystalLLM::StreamAccumulator.new
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "a<thi"))
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "nk>b</think>c"))

      accumulator.content.should eq("ac")
      accumulator.thinking.try(&.text).should eq("b")
    end

    it "treats text without think tags as pure content" do
      accumulator = CrystalLLM::StreamAccumulator.new
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "just text"))

      accumulator.content.should eq("just text")
      accumulator.thinking.should be_nil
    end
  end

  describe "structured thinking (Chunk#thinking)" do
    it "accumulates thinking text across chunks and keeps the first signature" do
      accumulator = CrystalLLM::StreamAccumulator.new
      accumulator.add(CrystalLLM::Chunk.new(
        role: :assistant, content: nil,
        thinking: CrystalLLM::Thinking.build(text: "Let me ")
      ))
      accumulator.add(CrystalLLM::Chunk.new(
        role: :assistant, content: nil,
        thinking: CrystalLLM::Thinking.build(text: "think.")
      ))
      # signature arrives on a later (signature_delta-style) chunk
      accumulator.add(CrystalLLM::Chunk.new(
        role: :assistant, content: "answer",
        thinking: CrystalLLM::Thinking.build(signature: "sig-A")
      ))
      # a second signature must NOT overwrite the first
      accumulator.add(CrystalLLM::Chunk.new(
        role: :assistant, content: nil,
        thinking: CrystalLLM::Thinking.build(signature: "sig-B")
      ))

      thinking = accumulator.thinking.should_not be_nil
      thinking.text.should eq("Let me think.")
      thinking.signature.should eq("sig-A")

      message = accumulator.to_message(nil)
      msg_thinking = message.thinking.should_not be_nil
      msg_thinking.text.should eq("Let me think.")
      msg_thinking.signature.should eq("sig-A")
      message.content.should eq("answer")
    end

    it "leaves Message#thinking nil when no chunk carries thinking" do
      accumulator = CrystalLLM::StreamAccumulator.new
      accumulator.add(CrystalLLM::Chunk.new(role: :assistant, content: "hi"))
      accumulator.to_message(nil).thinking.should be_nil
    end
  end

  describe "#to_message" do
    it "returns an assistant message with nil content when nothing accumulated" do
      message = CrystalLLM::StreamAccumulator.new.to_message(nil)
      message.role.should eq(CrystalLLM::Role::Assistant)
      message.content.should be_nil
      message.tool_calls.should be_nil
    end

    # REGRESSION (BUG 1): raw partial-JSON fragments split across deltas must be
    # concatenated and parsed ONCE. Each fragment is individually unparseable; the
    # old hash-merge path dropped them and produced empty arguments.
    it "concatenates raw_arguments fragments across deltas and parses once" do
      accumulator = CrystalLLM::StreamAccumulator.new
      # Leading delta: id + name, empty raw fragment (the OpenAI/Anthropic shape).
      accumulator.add(CrystalLLM::Chunk.new(
        role: :assistant, content: nil,
        tool_calls: {"call_1" => CrystalLLM::ToolCall.new(id: "call_1", name: "weather", raw_arguments: "")}
      ))
      # Continuation deltas (id == "" marks a continuation), each an unparseable partial.
      ["{\"lat", "itude\": \"52.5", "200\", \"lon", "gitude\": \"13.4050\"}"].each do |frag|
        accumulator.add(CrystalLLM::Chunk.new(
          role: :assistant, content: nil,
          tool_calls: {"" => CrystalLLM::ToolCall.new(id: "", name: "", raw_arguments: frag)}
        ))
      end

      tool_calls = accumulator.to_message(nil).tool_calls.should_not be_nil
      args = tool_calls["call_1"].arguments
      args["latitude"].as_s.should eq("52.5200")
      args["longitude"].as_s.should eq("13.4050")
    end

    it "falls back to {} when the concatenated raw_arguments stream is invalid JSON" do
      accumulator = CrystalLLM::StreamAccumulator.new
      accumulator.add(CrystalLLM::Chunk.new(
        role: :assistant, content: nil,
        tool_calls: {"call_1" => CrystalLLM::ToolCall.new(id: "call_1", name: "x", raw_arguments: "{not json")}
      ))

      tool_calls = accumulator.to_message(nil).tool_calls.should_not be_nil
      tool_calls["call_1"].arguments.should eq({} of String => JSON::Any)
    end

    it "parses streamed JSON argument fragments into a Hash" do
      accumulator = CrystalLLM::StreamAccumulator.new
      tool_call = CrystalLLM::ToolCall.new(
        id: "call_1", name: "weather",
        arguments: {"city" => JSON::Any.new("Paris")}
      )
      accumulator.add(CrystalLLM::Chunk.new(
        role: :assistant, content: nil, tool_calls: {"call_1" => tool_call}
      ))

      tool_calls = accumulator.to_message(nil).tool_calls.should_not be_nil
      tool_calls["call_1"].arguments["city"].as_s.should eq("Paris")
    end
  end
end
