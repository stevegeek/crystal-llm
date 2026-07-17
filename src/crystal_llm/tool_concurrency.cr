# ported from lib/ruby_llm/tool_concurrency.rb @ ruby_llm 1.16.0
#
# Divergence: Ruby offers `:threads` and `:fibers` modes and (for threads) wraps
# each call in the Rails executor. Crystal's runtime concurrency IS fibers, so
# "fibers" is the ONLY mode; "threads" is unsupported (it raises upstream in
# `Chat#normalize_tool_concurrency`). There is no Rails executor to wrap, and the
# Ruby `run_with_threads`/`run_with_fibers`/`capture_result`/`run_tool_call`/
# `rails_executor` helpers collapse into a single fiber-spawning `run`. The public
# contract is preserved: every call runs concurrently, `on_result` fires as each
# finishes (completion order), results come back in input order, and the first
# captured error is re-raised after all calls complete.
require "./tool_call"
require "./tool"

module CrystalLLM
  # Runs multiple tool calls concurrently on Crystal fibers.
  module ToolConcurrency
    MODES = ["fibers"]

    # A single call's outcome. `index` preserves input order for the results
    # array; exactly one of `value`/`error` is set. The value type is
    # `Chat#execute_tool`'s return type (`ToolResult`).
    record Result,
      index : Int32,
      tool_call : ToolCall,
      value : ToolResult? = nil,
      error : Exception? = nil

    def self.modes : Array(String)
      MODES
    end

    def self.supported?(name : String) : Bool
      MODES.includes?(name)
    end

    # Executes every tool call concurrently. `on_result` (when given) is invoked
    # with `(tool_call, value)` as each call finishes — completion order, on the
    # calling fiber (so callers can serialize side effects such as appending
    # messages). Returns `{tool_call, value}` tuples in INPUT order. If any call
    # raised, the first error is re-raised after all calls have completed.
    def self.run(mode : String, tool_calls : Hash(String, ToolCall),
                 on_result : Proc(ToolCall, ToolResult, Nil)? = nil,
                 &execute : ToolCall -> ToolResult) : Array({ToolCall, ToolResult})
      channel = Channel(Result).new
      entries = tool_calls.values
      entries.each_with_index do |tool_call, index|
        spawn do
          channel.send(Result.new(index: index, tool_call: tool_call, value: execute.call(tool_call)))
        rescue error : Exception
          channel.send(Result.new(index: index, tool_call: tool_call, error: error))
        end
      end
      collect_results(channel, entries.size, on_result)
    end

    # Drains `count` results off the channel (completion order), placing each into
    # its input-order slot, firing `on_result` for successes and collecting errors.
    # Re-raises the first error once every call has reported.
    private def self.collect_results(channel : Channel(Result), count : Int32,
                                     on_result : Proc(ToolCall, ToolResult, Nil)?) : Array({ToolCall, ToolResult})
      results = Array({ToolCall, ToolResult}?).new(count, nil)
      errors = [] of Exception

      count.times do
        result = channel.receive
        if error = result.error
          errors << error
        elsif value = result.value
          # Every non-error Result carries a value; a `ToolResult` is never falsy
          # (String/Hash/Content/Halt are all truthy), so this binds it safely.
          results[result.index] = {result.tool_call, value}
          on_result.try &.call(result.tool_call, value)
        end
      end

      raise errors.first unless errors.empty?

      results.compact
    end
  end
end
