# ported from lib/ruby_llm/providers/gemini/tools.rb @ ruby_llm 1.15.0
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
        if content.is_a?(String) && !content.empty?
          formatted = Media.format_content(content)
          if arr = formatted.as_a?
            parts.concat(arr)
          else
            parts << formatted
          end
        elsif content.is_a?(Content)
          formatted = Media.format_content(content)
          if arr = formatted.as_a?
            parts.concat(arr)
          else
            parts << formatted
          end
        end

        # NOTE: ruby_llm falls back to msg.thinking.signature for the first tool call
        # when the call itself has no thoughtSignature; Message#thinking is deferred in
        # CrystalLLM, so that fallback is omitted (documented divergence).
        if tool_calls = msg.tool_calls
          tool_calls.each_value do |tool_call|
            function_call = {
              "name" => JSON::Any.new(tool_call.name),
              "args" => JSON::Any.new(tool_call.arguments),
            } of String => JSON::Any
            part = {"functionCall" => JSON::Any.new(function_call)} of String => JSON::Any
            if signature = tool_call.thought_signature
              part["thoughtSignature"] = JSON::Any.new(signature)
            end
            parts << JSON::Any.new(part)
          end
        end

        parts
      end

      # Serializes a tool-result message into a Gemini `functionResponse` part.
      def format_tool_result(msg : Message, function_name : String? = nil) : Array(JSON::Any)
        name = function_name || msg.tool_call_id || ""
        content = msg.content
        formatted = if content.nil? || (content.is_a?(String) && content.empty?)
                      Media.format_content("(no output)")
                    else
                      Media.format_content(content)
                    end

        response = {
          "name"    => JSON::Any.new(name),
          "content" => formatted,
        } of String => JSON::Any

        [JSON::Any.new({
          "functionResponse" => JSON::Any.new({
            "name"     => JSON::Any.new(name),
            "response" => JSON::Any.new(response),
          } of String => JSON::Any),
        } of String => JSON::Any)]
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
      private def convert_property(property_any : JSON::Any) : JSON::Any
        property_schema = property_any.as_h? || return JSON::Any.new({"type" => JSON::Any.new("STRING")} of String => JSON::Any)

        type = param_type_for_gemini(property_schema["type"]?.try(&.as_s?))
        property = {"type" => JSON::Any.new(type)} of String => JSON::Any

        copy_common_attributes(property, property_schema)

        case type
        when "ARRAY"
          items = property_schema["items"]? || JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)
          property["items"] = convert_property(items)
          copy_tool_attributes(property, property_schema, %w[minItems maxItems])
        when "OBJECT"
          nested = {} of String => JSON::Any
          if props = property_schema["properties"]?.try(&.as_h?)
            props.each { |key, value| nested[key] = convert_property(value) }
          end
          property["properties"] = JSON::Any.new(nested)
          if req = property_schema["required"]?.try(&.as_a?)
            property["required"] = JSON::Any.new(req.compact_map(&.as_s?).map { |name| JSON::Any.new(name) })
          end
        end

        JSON::Any.new(property)
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
