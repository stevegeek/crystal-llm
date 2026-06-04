# ported from lib/ruby_llm/tool_call.rb @ ruby_llm 1.15.0
require "json"

module CrystalLLM
  # A function call from an AI model to a Tool. `arguments` is the parsed JSON
  # the model supplied (string-keyed JSON values — design's JSONData shape).
  class ToolCall
    getter id : String
    getter name : String
    getter arguments : Hash(String, JSON::Any)
    property thought_signature : String?

    def initialize(@id : String, @name : String,
                   @arguments : Hash(String, JSON::Any) = {} of String => JSON::Any,
                   @thought_signature : String? = nil)
    end

    def to_h
      {id: @id, name: @name, arguments: @arguments, thought_signature: @thought_signature}
    end
  end
end
