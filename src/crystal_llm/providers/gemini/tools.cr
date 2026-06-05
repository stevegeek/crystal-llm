# ported from lib/ruby_llm/providers/gemini/tools.rb @ ruby_llm 1.15.0
#
# Tool (de)serialization for the Gemini API. Gemini wraps all functions in a
# single `tools: [{ functionDeclarations: [...] }]` entry, and uses UPPERCASE
# JSON-schema-ish types (OBJECT / ARRAY / STRING / INTEGER / NUMBER / BOOLEAN).
#
# Divergences:
# - `tool.params_schema` is non-nilable in CrystalLLM (it always returns at least an
#   empty-object schema), so the Ruby `params_schema || schema_from_parameters`
#   fallback collapses to just `tool.params_schema` here. An empty-object schema
#   still converts (no properties) — Gemini omits `parameters` only if absent, but
#   ruby_llm always sends it once `parameters_schema` is truthy; we always send it.
# - JSON-schema keys arrive as Strings on the wire (JSON::Any), so the Ruby
#   string-or-symbol key lookups collapse to plain String keys.
# - SecureRandom.uuid -> UUID.random for the synthetic tool-call id.
# - `build_tool_config` (toolConfig / functionCallingConfig) is wired into
#   render_payload (when `tool_prefs["choice"]` is set — see gemini/chat.cr).
require "json"
require "uuid"
require "../gemini"

module CrystalLLM
  module Providers
    class Gemini < Provider
      # Gemini `tools` is a single-element array carrying all functionDeclarations.
      def format_tools(tools : Hash(String, Tool)) : Array(JSON::Any)
        return [] of JSON::Any if tools.empty?

        declarations = tools.map { |_, tool| function_declaration_for(tool) }
        [JSON::Any.new({
          "functionDeclarations" => JSON::Any.new(declarations),
        } of String => JSON::Any)]
      end

      # The Gemini functionDeclaration for a single Tool.
      def function_declaration_for(tool : Tool) : JSON::Any
        parameters_schema = tool.params_schema

        declaration = {
          "name"        => JSON::Any.new(tool.name),
          "description" => JSON::Any.new(tool.description),
        } of String => JSON::Any

        if converted = convert_tool_schema_to_gemini(parameters_schema)
          declaration["parameters"] = converted
        end

        return JSON::Any.new(declaration) if tool.provider_params.empty?

        JSON::Any.new(Utils.deep_merge(declaration, tool.provider_params))
      end

      # Converts a JSON-schema object into Gemini's uppercase-typed OBJECT schema.
      # Raises if the top-level schema is not an object (Gemini requirement).
      def convert_tool_schema_to_gemini(schema : Hash(String, JSON::Any)) : JSON::Any?
        return nil if schema.empty?

        type = schema["type"]?.try(&.as_s?)
        unless type == "object"
          raise ArgumentError.new("Gemini tool parameters must be objects")
        end

        properties = {} of String => JSON::Any
        if props = schema["properties"]?.try(&.as_h?)
          props.each do |key, value|
            properties[key] = convert_property(value.as_h? || {} of String => JSON::Any)
          end
        end

        required = [] of JSON::Any
        if req = schema["required"]?.try(&.as_a?)
          req.each { |entry| required << JSON::Any.new(entry.as_s? || entry.raw.to_s) }
        end

        JSON::Any.new({
          "type"       => JSON::Any.new("OBJECT"),
          "properties" => JSON::Any.new(properties),
          "required"   => JSON::Any.new(required),
        } of String => JSON::Any)
      end

      # Converts one property schema (recursively for arrays/objects).
      # ameba:disable Metrics/CyclomaticComplexity
      def convert_property(property_schema : Hash(String, JSON::Any)) : JSON::Any
        working = normalize_any_of_schema(property_schema) || property_schema

        type = param_type_for_gemini(working["type"]?.try(&.as_s?))

        property = {"type" => JSON::Any.new(type)} of String => JSON::Any

        copy_common_attributes(property, property_schema)
        copy_common_attributes(property, working)

        case type
        when "ARRAY"
          items_schema = (working["items"]?.try(&.as_h?)) ||
                         (property_schema["items"]?.try(&.as_h?)) ||
                         {"type" => JSON::Any.new("string")}
          property["items"] = convert_property(items_schema)
          copy_tool_attributes(property, working, %w[minItems maxItems])
          copy_tool_attributes(property, property_schema, %w[minItems maxItems])
        when "OBJECT"
          nested = {} of String => JSON::Any
          if props = working["properties"]?.try(&.as_h?)
            props.each do |key, value|
              nested[key] = convert_property(value.as_h? || {} of String => JSON::Any)
            end
          end
          property["properties"] = JSON::Any.new(nested)
          required = working["required"]?.try(&.as_a?) || property_schema["required"]?.try(&.as_a?)
          if required
            property["required"] = JSON::Any.new(required.map { |entry| JSON::Any.new(entry.as_s? || entry.raw.to_s) })
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
          value = schema_value(source, attribute)
          next if value.nil?

          target[attribute] = value
        end
      end

      # Collapses an `anyOf` (the common `[T, null]` nullable shape) into a single
      # schema with `nullable: true`. Returns nil when there is no anyOf.
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

      private def schema_value(source : Hash(String, JSON::Any), attribute : String) : JSON::Any?
        case attribute
        when "multipleOf"
          source["multipleOf"]? || source["multiple_of"]?
        when "minItems"
          source["minItems"]? || source["min_items"]?
        when "maxItems"
          source["maxItems"]? || source["max_items"]?
        else
          source[attribute]?
        end
      end

      private def param_type_for_gemini(type : String?) : String
        case (type || "").downcase
        when "integer"                   then "INTEGER"
        when "number", "float", "double" then "NUMBER"
        when "boolean"                   then "BOOLEAN"
        when "array"                     then "ARRAY"
        when "object"                    then "OBJECT"
        else                                  "STRING"
        end
      end

      # ---- response-side: extracting tool calls from a completion/stream chunk ----

      # Builds the typed ToolCall map from a Gemini response's `functionCall` parts.
      # Each call gets a synthetic UUID id (Gemini doesn't supply ids). Returns nil
      # when there are no function-call parts.
      def extract_tool_calls(data : JSON::Any?) : Hash(String, ToolCall)?
        return nil if data.nil?

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

      # ---- request-side: assistant tool-call parts + tool-result parts ----

      # Builds the `parts` for an assistant message that issued tool calls
      # (`{functionCall: {name, args}}` per call, plus any leading content parts).
      def format_tool_call(msg : Message) : Array(JSON::Any)
        parts = [] of JSON::Any

        content = msg.content
        if content && !(content.is_a?(String) && content.empty?)
          Media.format_content(content).each { |part| parts << part }
        end

        # ruby_llm gemini/tools.rb: when a tool call carries no thoughtSignature, the
        # FIRST such call borrows the message-level thinking signature (used once).
        fallback_signature = msg.thinking.try(&.signature)
        used_fallback = false

        if tool_calls = msg.tool_calls
          tool_calls.each do |_, tool_call|
            call = {
              "name" => JSON::Any.new(tool_call.name),
              "args" => JSON::Any.new(tool_call.arguments),
            } of String => JSON::Any
            part = {"functionCall" => JSON::Any.new(call)} of String => JSON::Any

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

      # Builds the `parts` for a tool-result message (`{functionResponse: {...}}`).
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

      # toolConfig.functionCallingConfig wire value. `tool_choice` is "auto"/"none"/
      # "required" or a named-tool string; "required" or a specific name map to mode
      # "any" (the latter adding allowedFunctionNames). Emitted by render_payload from
      # `tool_prefs["choice"]`.
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
    end
  end
end
