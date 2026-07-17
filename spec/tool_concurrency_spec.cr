require "./spec_helper"

private def probe_call(id : String, name : String = "probe") : CrystalLLM::ToolCall
  CrystalLLM::ToolCall.new(id: id, name: name)
end

describe CrystalLLM::ToolConcurrency do
  it "supports only fibers (threads is N/A in Crystal)" do
    CrystalLLM::ToolConcurrency.modes.should eq(["fibers"])
    CrystalLLM::ToolConcurrency.supported?("fibers").should be_true
    CrystalLLM::ToolConcurrency.supported?("threads").should be_false
  end

  it "runs all tool calls, returns results in input order, fires on_result in completion order" do
    calls = {
      "a" => probe_call("a", "slow"),
      "b" => probe_call("b", "fast"),
    }
    finished = [] of String
    on_result = ->(call : CrystalLLM::ToolCall, _value : CrystalLLM::ToolResult) do
      finished << call.id
      nil
    end

    results = CrystalLLM::ToolConcurrency.run("fibers", calls, on_result: on_result) do |call|
      sleep 50.milliseconds if call.name == "slow"
      "result-#{call.id}".as(CrystalLLM::ToolResult)
    end

    # Results collected in INPUT order regardless of completion order.
    results.map { |pair| pair.last.as(String) }.should eq(["result-a", "result-b"])
    # on_result fired in COMPLETION order (fast "b" finishes before slow "a").
    finished.should eq(["b", "a"])
  end

  it "raises the first error after all calls complete" do
    calls = {
      "a" => probe_call("a", "boom"),
      "b" => probe_call("b", "ok"),
    }
    ran = [] of String

    expect_raises(Exception, "kaboom") do
      CrystalLLM::ToolConcurrency.run("fibers", calls, on_result: nil) do |call|
        ran << call.id
        raise "kaboom" if call.name == "boom"
        "ok".as(CrystalLLM::ToolResult)
      end
    end

    # The healthy call still ran to completion before the error surfaced.
    ran.sort.should eq(["a", "b"])
  end

  it "returns an empty array for no tool calls" do
    calls = {} of String => CrystalLLM::ToolCall
    CrystalLLM::ToolConcurrency.run("fibers", calls, on_result: nil) do |call|
      "x-#{call.id}".as(CrystalLLM::ToolResult)
    end.should be_empty
  end
end
