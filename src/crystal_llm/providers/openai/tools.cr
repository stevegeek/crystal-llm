# ported from lib/ruby_llm/providers/openai/tools.rb @ ruby_llm 1.15.0
#
# Tool (de)serialization for the OpenAI chat API.
#
# Divergences:
# - `tool.params_schema` is non-nilable in CrystalLLM (it always returns at least
#   an empty-object schema), so the Ruby `tool.params_schema || schema_from_parameters`
#   fallback collapses to just `tool.params_schema` here.
# - `parse_tool_calls(tool_calls, parse_arguments:)`: arguments arrive as a JSON
#   string from OpenAI. With `parse_arguments: true` (sync path) we JSON.parse them
#   into the typed `Hash(String, JSON::Any)`. With `parse_arguments: false` (stream
#   path) ruby_llm keeps the raw String fragment; CrystalLLM's ToolCall#arguments is
#   a typed Hash, so the streaming buffer (StreamAccumulator::ToolCallBuffer) merges
#   parsed hashes — we best-effort parse the fragment here and keep `{}` if partial.
# - `build_tool_choice` returns a JSON::Any (string for auto/none/required, object
#   for a named function), since tool_prefs is JSON-wire data.
require "json"
require "../openai"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      EMPTY_PARAMETERS_SCHEMA = {
        "type"                 => JSON::Any.new("object"),
        "properties"           => JSON::Any.new({} of String => JSON::Any),
        "required"             => JSON::Any.new([] of JSON::Any),
        "additionalProperties" => JSON::Any.new(false),
        "strict"               => JSON::Any.new(true),
      } of String => JSON::Any

      # The OpenAI `tools[]` entry for a single Tool.
      def tool_for(tool : Tool) : JSON::Any
        parameters_schema = tool.params_schema
        parameters_schema = EMPTY_PARAMETERS_SCHEMA if parameters_schema.empty?

        function = {
          "name"        => JSON::Any.new(tool.name),
          "description" => JSON::Any.new(tool.description),
          "parameters"  => JSON::Any.new(parameters_schema),
        } of String => JSON::Any

        definition = {
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new(function),
        } of String => JSON::Any

        return JSON::Any.new(definition) if tool.provider_params.empty?

        JSON::Any.new(Utils.deep_merge(definition, tool.provider_params))
      end

      # Serializes assistant tool_calls back into the OpenAI wire shape.
      def format_tool_calls(tool_calls : Hash(String, ToolCall)?) : JSON::Any?
        return nil if tool_calls.nil? || tool_calls.empty?

        calls = tool_calls.map do |_, call_obj|
          function = {
            "name"      => JSON::Any.new(call_obj.name),
            "arguments" => JSON::Any.new(call_obj.arguments.to_json),
          } of String => JSON::Any
          call = {
            "id"       => JSON::Any.new(call_obj.id),
            "type"     => JSON::Any.new("function"),
            "function" => JSON::Any.new(function),
          } of String => JSON::Any
          if sig = call_obj.thought_signature
            call["extra_content"] = JSON::Any.new({
              "google" => JSON::Any.new({"thought_signature" => JSON::Any.new(sig)} of String => JSON::Any),
            } of String => JSON::Any)
          end
          JSON::Any.new(call)
        end
        JSON::Any.new(calls)
      end

      # Parses OpenAI's `tool_calls[]` into typed ToolCall values.
      def parse_tool_calls(tool_calls : JSON::Any?, parse_arguments : Bool = true) : Hash(String, ToolCall)?
        arr = tool_calls.try(&.as_a?)
        return nil if arr.nil? || arr.empty?

        result = {} of String => ToolCall
        arr.each do |tc_any|
          tc = tc_any.as_h? || next
          id = tc["id"]?.try(&.as_s?) || ""
          func = tc["function"]?.try(&.as_h?) || {} of String => JSON::Any
          name = func["name"]?.try(&.as_s?) || ""
          arguments = parse_tool_call_arguments(func["arguments"]?)

          result[id] = ToolCall.new(
            id: id,
            name: name,
            arguments: arguments,
            thought_signature: extract_tool_call_thought_signature(tc)
          )
        end
        result
      end

      # Coerces OpenAI's stringified `arguments` (or already-parsed object) into the
      # typed args hash. Returns `{}` for nil/empty/unparseable (streaming partials).
      private def parse_tool_call_arguments(arguments : JSON::Any?) : Hash(String, JSON::Any)
        return {} of String => JSON::Any if arguments.nil?

        if obj = arguments.as_h?
          return obj
        end

        str = arguments.as_s?
        return {} of String => JSON::Any if str.nil? || str.empty?

        parsed = JSON.parse(str)
        parsed.as_h? || {} of String => JSON::Any
      rescue JSON::ParseException
        {} of String => JSON::Any
      end

      private def extract_tool_call_thought_signature(tool_call : Hash(String, JSON::Any)) : String?
        tool_call.dig?("extra_content", "google", "thought_signature").try(&.as_s?)
      end

      # tool_choice wire value: a bare keyword string, or a named-function object.
      def build_tool_choice(tool_choice : String) : JSON::Any
        case tool_choice
        when "auto", "none", "required"
          JSON::Any.new(tool_choice)
        else
          JSON::Any.new({
            "type"     => JSON::Any.new("function"),
            "function" => JSON::Any.new({"name" => JSON::Any.new(tool_choice)} of String => JSON::Any),
          } of String => JSON::Any)
        end
      end
    end
  end
end
