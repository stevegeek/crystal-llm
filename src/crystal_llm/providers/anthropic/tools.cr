# ported from lib/ruby_llm/providers/anthropic/tools.rb @ ruby_llm 1.15.0
#
# Tool (de)serialization for the Anthropic Messages API.
#
# Divergences:
# - Anthropic's tool entry is flat (`{name, description, input_schema}`), unlike
#   OpenAI's `{type:"function", function:{...}}` wrapper.
# - `tool.params_schema ||  SchemaDefinition.from_parameters(...)` collapses to just
#   `tool.params_schema` in CrystalLLM (params_schema is non-nilable, always at least
#   an empty-object schema). When it is the empty-object schema we still substitute
#   Anthropic's `default_input_schema` to match ruby_llm's `default_input_schema`.
# - Anthropic tool_use blocks already carry `input` as a parsed JSON object, so
#   `parse_tool_calls` reads `block["input"]` directly (no string-parsing like OpenAI).
# - `build_tool_choice` returns a JSON::Any object (`{type: ...}`), matching ruby_llm's
#   symbol-typed hash, with symbols-as-runtime-data lowered to strings.
require "json"
require "../anthropic"

module CrystalLLM
  module Providers
    class Anthropic < Provider
      # Tool (de)serialization for the Anthropic Messages API.
      module Tools
        extend self

        DEFAULT_INPUT_SCHEMA = {
          "type"                 => JSON::Any.new("object"),
          "properties"           => JSON::Any.new({} of String => JSON::Any),
          "required"             => JSON::Any.new([] of JSON::Any),
          "additionalProperties" => JSON::Any.new(false),
          "strict"               => JSON::Any.new(true),
        } of String => JSON::Any

        # The Anthropic `tools[]` entry for a single Tool.
        def function_for(tool : Tool) : JSON::Any
          input_schema = tool.params_schema
          input_schema = DEFAULT_INPUT_SCHEMA if input_schema.empty?

          declaration = {
            "name"         => JSON::Any.new(tool.name),
            "description"  => JSON::Any.new(tool.description),
            "input_schema" => JSON::Any.new(input_schema),
          } of String => JSON::Any

          return JSON::Any.new(declaration) if tool.provider_params.empty?

          JSON::Any.new(Utils.deep_merge(declaration, tool.provider_params))
        end

        # The `tool_use` content blocks from a list of response content blocks.
        def find_tool_uses(blocks : Array(JSON::Any)) : Array(JSON::Any)
          blocks.select do |block|
            (h = block.as_h?) && h["type"]?.try(&.as_s?) == "tool_use"
          end
        end

        # A single `tool_use` content block for an assistant tool call.
        def format_tool_use_block(tool_call : ToolCall) : JSON::Any
          JSON::Any.new({
            "type"  => JSON::Any.new("tool_use"),
            "id"    => JSON::Any.new(tool_call.id),
            "name"  => JSON::Any.new(tool_call.name),
            "input" => JSON::Any.new(tool_call.arguments),
          } of String => JSON::Any)
        end

        # The `user` message carrying a `tool_result` block for a tool result message.
        def format_tool_result(msg : Message) : JSON::Any
          content = msg.content
          if content.is_a?(Content::Raw)
            return JSON::Any.new({
              "role"    => JSON::Any.new("user"),
              "content" => content.value,
            } of String => JSON::Any)
          end

          JSON::Any.new({
            "role"    => JSON::Any.new("user"),
            "content" => JSON::Any.new([format_tool_result_block(msg)] of JSON::Any),
          } of String => JSON::Any)
        end

        def format_tool_result_block(msg : Message) : JSON::Any
          content = msg.content
          text = content.is_a?(String) ? content : content.try(&.to_s)
          text = "(no output)" if text.nil? || text.empty?

          JSON::Any.new({
            "type"        => JSON::Any.new("tool_result"),
            "tool_use_id" => JSON::Any.new(msg.tool_call_id),
            "content"     => Media.format_content(text),
          } of String => JSON::Any)
        end

        # Parses Anthropic `tool_use` content blocks into typed ToolCall values.
        # Accepts a single block (JSON object) or an array of blocks. Returns nil
        # when there are no tool_use blocks.
        def parse_tool_calls(content_blocks : JSON::Any?) : Hash(String, ToolCall)?
          return nil if content_blocks.nil?

          blocks = content_blocks.as_a? || [content_blocks]

          result = {} of String => ToolCall
          blocks.each do |block_any|
            block = block_any.as_h? || next
            next unless block["type"]?.try(&.as_s?) == "tool_use"

            id = block["id"]?.try(&.as_s?) || ""
            name = block["name"]?.try(&.as_s?) || ""
            arguments = block["input"]?.try(&.as_h?) || {} of String => JSON::Any

            result[id] = ToolCall.new(id: id, name: name, arguments: arguments)
          end

          result.empty? ? nil : result
        end

        # tool_choice wire value. `choice` is one of "auto"/"none"/"required" or a
        # named-tool string; `parallel` is "one" to disable parallel tool use (or nil
        # to leave unspecified). Mirrors ruby_llm's `build_tool_choice(tool_prefs)`.
        def build_tool_choice(choice : String?, parallel : String?) : JSON::Any
          choice = "auto" if choice.nil?

          type = case choice
                 when "auto", "none" then choice
                 when "required"     then "any"
                 else                     "tool"
                 end

          tc = {"type" => JSON::Any.new(type)} of String => JSON::Any
          tc["name"] = JSON::Any.new(choice) if type == "tool"
          if type != "none" && !parallel.nil?
            tc["disable_parallel_tool_use"] = JSON::Any.new(parallel == "one")
          end
          JSON::Any.new(tc)
        end
      end
    end
  end
end
