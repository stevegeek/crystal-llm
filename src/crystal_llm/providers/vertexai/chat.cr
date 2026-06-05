# ported from lib/ruby_llm/providers/vertexai/chat.rb + lib/ruby_llm/providers/gemini/chat.rb @ ruby_llm 1.15.0
#
# The Vertex AI / Gemini chat request/response surface.
#
# completion_url is the VertexAI override (projects/.../publishers/google/models/<m>:generateContent);
# render_payload / parse_completion_response / format_messages are the Gemini wire format.
#
# Divergences:
# - `render_payload` matches the completion-pipeline hook signature, including
#   `tool_prefs`. When tools are present and `choice` is set it emits
#   `toolConfig.functionCallingConfig` via `build_tool_config(choice)` (Gemini
#   shape); Vertex has no parallel-call control, so `calls` is ignored. Returns
#   Hash(String, JSON::Any).
# - `schema` is a JSON::Any? envelope. Gemini structured-output conversion is PORTED
#   and SHARED with the native Gemini provider: render_payload delegates to
#   `GeminiSchema.structured_output_config` (gemini/schema.cr) — responseMimeType plus
#   responseJsonSchema (Gemini >= 2.5) or the rewritten responseSchema.
# - `thinking` is a Thinking::Config?; thinkingConfig wiring is DEFERRED (the schema/
#   thinking conversion lives with structured-output, out of chat-only scope).
# - thinking text/signature *extraction* into Message is deferred (Message#thinking
#   deferred); thinking_tokens ARE wired.
# - `response.body` is the raw String (Crest); parse_completion_response JSON.parses it.
# - model_id fallback: ruby_llm reads `response.env.url.path.split('/')[3]`; Crest has
#   no parsed env.url here, so we fall back to the `@last_model` captured in render_payload.
require "json"
require "../vertexai"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      # The model id captured at render time (Gemini's `@model`), used as the
      # model_id fallback when the response omits `modelVersion`.
      @last_model : String? = nil

      def completion_url : String
        "projects/#{@config.vertexai_project_id}/locations/#{@config.vertexai_location}/" \
        "publishers/google/models/#{@last_model}:generateContent"
      end

      def render_payload(messages : Array(Message), tools : Hash(String, Tool),
                         temperature : Float64?, model : Model::Info,
                         stream : Bool = false, schema : JSON::Any? = nil,
                         thinking : Thinking::Config? = nil,
                         tool_prefs : Hash(String, String?)? = nil) : Hash(String, JSON::Any)
        @last_model = model.id
        prefs = tool_prefs || {} of String => String?

        generation_config = {} of String => JSON::Any
        generation_config["temperature"] = JSON::Any.new(temperature) unless temperature.nil?

        # Structured-output schema conversion via the shared GeminiSchema rewriter +
        # responseJsonSchema-vs-responseSchema version gate (gemini/schema.cr).
        if schema
          GeminiSchema.structured_output_config(schema, model).each { |k, v| generation_config[k] = v }
        end

        payload = {
          "contents"         => JSON::Any.new(format_messages(messages)),
          "generationConfig" => JSON::Any.new(generation_config),
        } of String => JSON::Any

        unless tools.empty?
          payload["tools"] = JSON::Any.new(format_tools(tools))
          # Vertex (Gemini wire) has no parallel-call control, so `calls` is ignored.
          if choice = prefs["choice"]?
            payload["toolConfig"] = build_tool_config(choice)
          end
        end

        payload
      end

      def parse_completion_response(response : Crest::Response) : Message
        body = response.body
        raise Error.new(response, "Empty response from Vertex AI") if body.empty?

        data = JSON.parse(body)

        if msg = data.dig?("error", "message").try(&.as_s?)
          raise Error.new(response, msg)
        end

        parts = data.dig?("candidates", 0, "content", "parts").try(&.as_a?) || [] of JSON::Any
        tool_calls = extract_tool_calls(data)

        usage = data["usageMetadata"]?.try(&.as_h?) || {} of String => JSON::Any

        Message.new(
          role: Role::Assistant,
          content: extract_text_parts(parts),
          tool_calls: tool_calls,
          input_tokens: input_tokens(usage),
          output_tokens: calculate_output_tokens(usage),
          cached_tokens: int_at(usage["cachedContentTokenCount"]?),
          thinking_tokens: int_at(usage["thoughtsTokenCount"]?),
          model_id: data["modelVersion"]?.try(&.as_s?) || @last_model,
          raw: data
        )
      end

      # ---- Message formatting (the Gemini MessageFormatter) ----

      # Formats CrystalLLM messages into Gemini `{role, parts}` entries, collapsing
      # consecutive tool-result messages into a single `function` entry (the
      # MessageFormatter behavior in gemini/chat.rb).
      def format_messages(messages : Array(Message)) : Array(JSON::Any)
        formatted = [] of JSON::Any
        # tool_call_id => tool name, remembered from a preceding assistant tool_call.
        tool_call_names = {} of String => String
        index = 0

        while index < messages.size
          message = messages[index]
          if message.role.tool?
            parts = [] of JSON::Any
            while index < messages.size && messages[index].role.tool?
              tool_message = messages[index]
              tool_name = tool_message.tool_call_id.try { |id| tool_call_names.delete(id) }
              parts.concat(format_tool_result(tool_message, tool_name))
              index += 1
            end
            formatted << JSON::Any.new({
              "role"  => JSON::Any.new("function"),
              "parts" => JSON::Any.new(parts),
            } of String => JSON::Any)
          else
            if message.tool_call?
              message.tool_calls.try &.each do |tool_call_id, tool_call|
                tool_call_names[tool_call_id] = tool_call.name
              end
            end
            formatted << JSON::Any.new({
              "role"  => JSON::Any.new(format_role(message.role)),
              "parts" => JSON::Any.new(format_parts(message)),
            } of String => JSON::Any)
            index += 1
          end
        end

        formatted
      end

      def format_role(role : Role) : String
        case role
        when .assistant? then "model"
        when .system?    then "user"
        when .tool?      then "function"
        else                  role.to_s.downcase
        end
      end

      # The `parts` array for a non-tool-result message.
      def format_parts(msg : Message) : Array(JSON::Any)
        if msg.tool_call?
          format_tool_call(msg)
        else
          Media.format_content(msg.content)
        end
      end

      # ---- Response content extraction ----

      # Joins the non-thought text parts; nil when empty.
      private def extract_text_parts(parts : Array(JSON::Any)) : String?
        text = String.build do |io|
          parts.each do |part_any|
            part = part_any.as_h? || next
            next if part["thought"]?.try(&.as_bool?)
            if t = part["text"]?.try(&.as_s?)
              io << t
            end
          end
        end
        text.empty? ? nil : text
      end

      # ---- Token accounting (gemini/chat.rb) ----

      # prompt - cached, floored at 0.
      private def input_tokens(usage : Hash(String, JSON::Any)) : Int32?
        prompt = int_at(usage["promptTokenCount"]?)
        return nil unless prompt
        cached = int_at(usage["cachedContentTokenCount"]?) || 0
        {prompt - cached, 0}.max
      end

      # candidates + thoughts.
      private def calculate_output_tokens(usage : Hash(String, JSON::Any)) : Int32?
        candidates = int_at(usage["candidatesTokenCount"]?) || 0
        thoughts = int_at(usage["thoughtsTokenCount"]?) || 0
        candidates + thoughts
      end

      # Coerce a JSON::Any numeric to Int32.
      private def int_at(value : JSON::Any?) : Int32?
        return nil if value.nil?
        case raw = value.raw
        when Int64   then raw.to_i32
        when Int32   then raw
        when Float64 then raw.to_i32
        else              nil
        end
      end
    end
  end
end
