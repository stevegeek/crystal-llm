# ported from lib/ruby_llm/providers/gemini/tools.rb @ ruby_llm 1.16.0
#   (Gemini wire format, used by VertexAI — see providers/vertexai.cr header)
#
# Tool (de)serialization for the Gemini/Vertex API.
#
# Divergences:
# - `tool.params_schema` is non-nilable in CrystalLLM (always at least an empty-object
#   schema), so ruby_llm's `params_schema || from_parameters(...)` fallback collapses
#   to `tool.params_schema`.
# - tool-call ids: ruby_llm uses `SecureRandom.uuid`; the port uses `UUID.random.to_s`.
# - `extract_tool_calls` returns the typed `Hash(String, ToolCall)?`; arguments arrive
#   as a JSON object (`functionCall.args`) — already the typed args hash.
require "json"
require "uuid"
require "../vertexai"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      # The Gemini `tools` payload: a single entry wrapping all functionDeclarations.
      def format_tools(tools : Hash(String, Tool)) : Array(JSON::Any)
        return [] of JSON::Any if tools.empty?

        declarations = tools.map { |_, tool| function_declaration_for(tool) }
        [JSON::Any.new({
          "functionDeclarations" => JSON::Any.new(declarations),
        } of String => JSON::Any)]
      end

      # Serializes an assistant tool-call message into Gemini `functionCall` parts.
      def format_tool_call(msg : Message) : Array(JSON::Any)
        parts = [] of JSON::Any

        content = msg.content
        if content && !(content.is_a?(String) && content.empty?)
          Media.format_content(content).each { |part| parts << part }
        end

        # ruby_llm gemini/tools.rb (Vertex shares the wire format): when a tool call
        # carries no thoughtSignature, the FIRST such call borrows the message-level
        # thinking signature (used once).
        fallback_signature = msg.thinking.try(&.signature)
        used_fallback = false

        if tool_calls = msg.tool_calls
          tool_calls.each_value do |tool_call|
            function_call = {
              "name" => JSON::Any.new(tool_call.name),
              "args" => JSON::Any.new(tool_call.arguments),
            } of String => JSON::Any
            part = {"functionCall" => JSON::Any.new(function_call)} of String => JSON::Any

            signature = tool_call.thought_signature
            if signature.nil? && (fb = fallback_signature) && !used_fallback
              signature = fb
              used_fallback = true
            end
            part["thoughtSignature"] = JSON::Any.new(signature) if signature

            parts << JSON::Any.new(part)
          end
        end

        parts
      end

      # Serializes a tool-result message into a Gemini `functionResponse` part.
      def format_tool_result(msg : Message, function_name : String? = nil) : Array(JSON::Any)
        name = function_name || msg.tool_call_id || ""
        content = msg.content
        content_value : Array(JSON::Any) = if content.nil? || (content.is_a?(String) && content.empty?)
          Media.format_content("(no output)")
        else
          Media.format_content(content)
        end

        response = {
          "name"    => JSON::Any.new(name),
          "content" => JSON::Any.new(content_value),
        } of String => JSON::Any

        [JSON::Any.new({
          "functionResponse" => JSON::Any.new({
            "name"     => JSON::Any.new(name),
            "response" => JSON::Any.new(response),
          } of String => JSON::Any),
        } of String => JSON::Any)]
      end

      # toolConfig.functionCallingConfig wire value (Gemini shape, inherited by
      # Vertex in ruby_llm). `tool_choice` is "auto"/"none"/"required" or a named-tool
      # string; "required" or a specific name map to mode "any" (the latter adding
      # allowedFunctionNames). Emitted by render_payload from `tool_prefs["choice"]`.
      def build_tool_config(tool_choice : String) : JSON::Any
        config = {} of String => JSON::Any
        config["mode"] = JSON::Any.new(forced_tool_choice?(tool_choice) ? "any" : tool_choice)
        if specific_tool_choice?(tool_choice)
          config["allowedFunctionNames"] = JSON::Any.new([JSON::Any.new(tool_choice)])
        end

        JSON::Any.new({
          "functionCallingConfig" => JSON::Any.new(config),
        } of String => JSON::Any)
      end

      private def forced_tool_choice?(tool_choice : String) : Bool
        tool_choice == "required" || specific_tool_choice?(tool_choice)
      end

      private def specific_tool_choice?(tool_choice : String) : Bool
        !%w[auto none required].includes?(tool_choice)
      end

      # Pulls `functionCall` parts out of a completion/stream response into ToolCalls.
      def extract_tool_calls(data : JSON::Any) : Hash(String, ToolCall)?
        parts = data.dig?("candidates", 0, "content", "parts").try(&.as_a?)
        return nil unless parts

        result = {} of String => ToolCall
        parts.each do |part_any|
          part = part_any.as_h? || next
          function_data = part["functionCall"]?.try(&.as_h?) || next

          id = UUID.random.to_s
          thought_signature = (part["thoughtSignature"]? || part["thought_signature"]?).try(&.as_s?)
          arguments = function_data["args"]?.try(&.as_h?) || {} of String => JSON::Any

          result[id] = ToolCall.new(
            id: id,
            name: function_data["name"]?.try(&.as_s?) || "",
            arguments: arguments,
            thought_signature: thought_signature
          )
        end

        result.empty? ? nil : result
      end

      # The Gemini `functionDeclaration` for a single Tool.
      private def function_declaration_for(tool : Tool) : JSON::Any
        declaration = {
          "name"        => JSON::Any.new(tool.name),
          "description" => JSON::Any.new(tool.description),
        } of String => JSON::Any

        schema = tool.params_schema
        unless schema.empty?
          declaration["parameters"] = convert_tool_schema_to_gemini(schema)
        end

        return JSON::Any.new(declaration) if tool.provider_params.empty?

        JSON::Any.new(Utils.deep_merge(declaration, tool.provider_params))
      end

      # Converts a JSON-schema object into the Gemini OBJECT schema shape.
      private def convert_tool_schema_to_gemini(schema : Hash(String, JSON::Any)) : JSON::Any
        unless schema["type"]?.try(&.as_s?) == "object"
          raise ArgumentError.new("Gemini tool parameters must be objects")
        end

        properties = {} of String => JSON::Any
        if props = schema["properties"]?.try(&.as_h?)
          props.each do |key, value|
            properties[key] = convert_property(value)
          end
        end

        required = (schema["required"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_s?)

        JSON::Any.new({
          "type"       => JSON::Any.new("OBJECT"),
          "properties" => JSON::Any.new(properties),
          "required"   => JSON::Any.new(required.map { |name| JSON::Any.new(name) }),
        } of String => JSON::Any)
      end

      # Converts one property schema; recurses for array items / nested objects.
      # ameba:disable Metrics/CyclomaticComplexity
      private def convert_property(property_any : JSON::Any) : JSON::Any
        property_schema = property_any.as_h? || return JSON::Any.new({"type" => JSON::Any.new("STRING")} of String => JSON::Any)

        # Collapse `anyOf` (the common `[T, null]` nullable shape) into a single
        # schema with `nullable: true` before converting — mirrors gemini/tools.cr
        # and ruby's inherited Gemini behaviour. The original is still consulted by
        # copy_common_attributes so attributes outside the anyOf branch survive.
        working = normalize_any_of_schema(property_schema) || property_schema

        type = param_type_for_gemini(working["type"]?.try(&.as_s?))
        property = {"type" => JSON::Any.new(type)} of String => JSON::Any

        copy_common_attributes(property, property_schema)
        copy_common_attributes(property, working)

        case type
        when "ARRAY"
          items = working["items"]? || property_schema["items"]? ||
                  JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)
          property["items"] = convert_property(items)
          copy_tool_attributes(property, working, %w[minItems maxItems])
          copy_tool_attributes(property, property_schema, %w[minItems maxItems])
        when "OBJECT"
          nested = {} of String => JSON::Any
          if props = (working["properties"]?.try(&.as_h?) || property_schema["properties"]?.try(&.as_h?))
            props.each { |key, value| nested[key] = convert_property(value) }
          end
          property["properties"] = JSON::Any.new(nested)
          if req = (working["required"]?.try(&.as_a?) || property_schema["required"]?.try(&.as_a?))
            property["required"] = JSON::Any.new(req.compact_map(&.as_s?).map { |name| JSON::Any.new(name) })
          end
        end

        JSON::Any.new(property)
      end

      # Collapses an `anyOf` (the common `[T, null]` nullable shape) into a single
      # schema with `nullable: true`. Returns nil when there is no anyOf. Ported
      # from gemini/tools.cr (which ports ruby's inherited Gemini behaviour).
      private def normalize_any_of_schema(schema : Hash(String, JSON::Any)) : Hash(String, JSON::Any)?
        any_of = schema["anyOf"]?.try(&.as_a?)
        return nil if any_of.nil? || any_of.empty?

        null_entries = [] of Hash(String, JSON::Any)
        non_null = [] of Hash(String, JSON::Any)
        any_of.each do |entry|
          entry_hash = entry.as_h? || next
          if (entry_hash["type"]?.try(&.as_s?)) == "null"
            null_entries << entry_hash
          else
            non_null << entry_hash
          end
        end

        if non_null.size == 1 && !null_entries.empty?
          normalized = non_null.first.dup
          normalized["nullable"] = JSON::Any.new(true)
          normalized
        elsif !non_null.empty?
          non_null.first.dup
        else
          {"type" => JSON::Any.new("string"), "nullable" => JSON::Any.new(true)} of String => JSON::Any
        end
      end

      private def copy_common_attributes(target : Hash(String, JSON::Any), source : Hash(String, JSON::Any)) : Nil
        copy_tool_attributes(target, source, %w[description enum format nullable maximum minimum multipleOf])
      end

      private def copy_tool_attributes(target : Hash(String, JSON::Any), source : Hash(String, JSON::Any),
                                       attributes : Array(String)) : Nil
        attributes.each do |attribute|
          if value = source[attribute]?
            target[attribute] = value
          end
        end
      end

      private def param_type_for_gemini(type : String?) : String
        case type.to_s.downcase
        when "integer"                   then "INTEGER"
        when "number", "float", "double" then "NUMBER"
        when "boolean"                   then "BOOLEAN"
        when "array"                     then "ARRAY"
        when "object"                    then "OBJECT"
        else                                  "STRING"
        end
      end
    end
  end
end
