# ported from lib/ruby_llm/providers/gemini/chat.rb @ ruby_llm 1.15.0
#
# The Gemini generateContent request/response surface. Gemini's payload is
# `{contents: [...], generationConfig: {...}, tools: [...], toolConfig: {...}}` —
# nothing like the OpenAI chat-completions shape.
#
# Divergences:
# - `render_payload` matches the completion pipeline's hook signature, including
#   `tool_prefs`. When tools are present and `choice` is set, it emits
#   `toolConfig.functionCallingConfig` via `build_tool_config(choice)` (mode
#   AUTO/NONE/ANY + allowedFunctionNames). Gemini has no parallel-call control, so
#   `calls` is ignored (ruby_llm parity). It returns `Hash(String, JSON::Any)` and
#   sets `@model_id` (ruby_llm's `@model` ivar) for completion_url/stream_url.
# - Structured-output schema translation is PORTED: `structured_output_config`
#   delegates to the shared GeminiSchema rewriter + responseJsonSchema-vs-
#   responseSchema version gate in gemini/schema.cr (see that file).
# - `thinking`: build_thinking_config (includeThoughts / thinkingLevel /
#   thinkingBudget) is ported. Thinking *text/signature* extraction into the
#   Message IS wired (thought parts + thoughtSignature -> `Thinking.build`);
#   thinking_tokens ARE wired.
# - `response.env.url.path` (Faraday) has no Crest analog reachable here; the
#   `model_id` fallback uses `data["modelVersion"]` only (the `@model_id` we set
#   on render is the same value), instead of re-deriving from the request URL.
# - `response.body` is a raw String (Crest); parse_completion_response JSON.parses it.
require "json"
require "../gemini"

module CrystalLLM
  module Providers
    class Gemini < Provider
      def completion_url : String
        "models/#{require_model_id}:generateContent"
      end

      def render_payload(messages : Array(Message), tools : Hash(String, Tool),
                         temperature : Float64?, model : Model::Info,
                         stream : Bool = false, schema : JSON::Any? = nil,
                         thinking : Thinking::Config? = nil,
                         tool_prefs : Hash(String, String?)? = nil) : Hash(String, JSON::Any)
        @model_id = model.id
        prefs = tool_prefs || {} of String => String?

        generation_config = {} of String => JSON::Any
        generation_config["temperature"] = JSON::Any.new(temperature) unless temperature.nil?

        if schema
          structured_output_config(schema, model).each { |k, v| generation_config[k] = v }
        end

        if thinking && thinking.enabled?
          generation_config["thinkingConfig"] = build_thinking_config(thinking)
        end

        payload = {
          "contents"         => JSON::Any.new(format_messages(messages)),
          "generationConfig" => JSON::Any.new(generation_config),
        } of String => JSON::Any

        unless tools.empty?
          payload["tools"] = JSON::Any.new(format_tools(tools))
          # Gemini doesn't support controlling parallel tool calls (`calls` ignored).
          if choice = prefs["choice"]?
            payload["toolConfig"] = build_tool_config(choice)
          end
        end

        payload
      end

      # generationConfig.thinkingConfig (includeThoughts + optional level/budget).
      def build_thinking_config(thinking : Thinking::Config) : JSON::Any
        config = {"includeThoughts" => JSON::Any.new(true)} of String => JSON::Any
        if effort = thinking.effort
          config["thinkingLevel"] = JSON::Any.new(effort)
        end
        if budget = thinking.budget
          config["thinkingBudget"] = JSON::Any.new(budget)
        end
        JSON::Any.new(config)
      end

      # ruby_llm's structured_output_config: responseMimeType: application/json plus
      # either responseJsonSchema (Gemini >= 2.5, cleaned raw schema) or responseSchema
      # (older, GeminiSchema-rewritten). Delegates to the shared rewriter + version gate
      # in gemini/schema.cr (also used by VertexAI).
      def structured_output_config(schema : JSON::Any, model : Model::Info) : Hash(String, JSON::Any)
        GeminiSchema.structured_output_config(schema, model)
      end

      def parse_completion_response(response : Crest::Response) : Message
        body = response.body
        raise Error.new(response, "Empty response from Gemini") if body.empty?

        data = JSON.parse(body)

        if msg = data.dig?("error", "message").try(&.as_s?)
          raise Error.new(response, msg)
        end

        parts = data.dig?("candidates", 0, "content", "parts").try(&.as_a?) || [] of JSON::Any
        tool_calls = extract_tool_calls(data)

        # ruby's `extract_text_parts(parts) || parse_content(data)`: parse_content
        # returns "" (not nil) for a function-call candidate. So a tool-only
        # response carries content "" rather than nil (nil-vs-empty parity).
        content = extract_text_parts(parts)
        content = "" if content.nil? && tool_calls

        Message.new(
          role: Role::Assistant,
          content: content,
          thinking: Thinking.build(
            text: extract_thought_parts(parts),
            signature: extract_thought_signature(parts)
          ),
          tool_calls: tool_calls,
          input_tokens: input_tokens(data),
          output_tokens: calculate_output_tokens(data),
          cached_tokens: usage_int(data, "cachedContentTokenCount"),
          thinking_tokens: usage_int(data, "thoughtsTokenCount"),
          model_id: data["modelVersion"]?.try(&.as_s?) || @model_id,
          raw: data
        )
      end

      # ---- token accounting (ported from chat.rb) ----

      def input_tokens(data : JSON::Any) : Int32?
        prompt_tokens = usage_int(data, "promptTokenCount")
        return nil unless prompt_tokens

        {prompt_tokens - (usage_int(data, "cachedContentTokenCount") || 0), 0}.max
      end

      def calculate_output_tokens(data : JSON::Any) : Int32?
        candidates = usage_int(data, "candidatesTokenCount") || 0
        thoughts = usage_int(data, "thoughtsTokenCount") || 0
        candidates + thoughts
      end

      # Reads an integer field out of `usageMetadata`, coercing JSON numerics.
      private def usage_int(data : JSON::Any, key : String) : Int32?
        value = data.dig?("usageMetadata", key)
        return nil if value.nil?
        case raw = value.raw
        when Int64   then raw.to_i32
        when Int32   then raw
        when Float64 then raw.to_i32
        else              nil
        end
      end

      # ---- content extraction (text-only; attachment rebuild deferred) ----

      # Joins the text of all non-thought parts; nil when empty. (Thought parts are
      # routed to Message#thinking via `extract_thought_parts`.)
      def extract_text_parts(parts : Array(JSON::Any)) : String?
        content = String.build do |io|
          parts.each do |part_any|
            part = part_any.as_h? || next
            next if part["thought"]?.try(&.as_bool?)
            if t = part["text"]?.try(&.as_s?)
              io << t
            end
          end
        end
        content.empty? ? nil : content
      end

      # Joins the text of all thought parts (parts flagged `thought: true`); nil when
      # empty. Mirrors ruby_llm's `extract_thought_parts`.
      def extract_thought_parts(parts : Array(JSON::Any)) : String?
        thoughts = String.build do |io|
          parts.each do |part_any|
            part = part_any.as_h? || next
            next unless part["thought"]?.try(&.as_bool?)
            if t = part["text"]?.try(&.as_s?)
              io << t
            end
          end
        end
        thoughts.empty? ? nil : thoughts
      end

      # The first thoughtSignature found across parts (top-level or under
      # functionCall, camelCase or snake_case). Mirrors ruby_llm's
      # `extract_thought_signature`.
      def extract_thought_signature(parts : Array(JSON::Any)) : String?
        parts.each do |part_any|
          part = part_any.as_h? || next
          sig = part["thoughtSignature"]?.try(&.as_s?) ||
                part["thought_signature"]?.try(&.as_s?) ||
                part.dig?("functionCall", "thoughtSignature").try(&.as_s?) ||
                part.dig?("functionCall", "thought_signature").try(&.as_s?)
          return sig if sig
        end
        nil
      end

      # ---- message formatting ----

      # Gemini `contents`: one entry per message, with consecutive `tool` (function)
      # results collapsed into a single `{role: "function", parts: [...]}` entry.
      # Ported from chat.rb's MessageFormatter.
      def format_messages(messages : Array(Message)) : Array(JSON::Any)
        MessageFormatter.new(self, messages).format
      end

      def format_role(role : Role) : String
        case role
        when .assistant? then "model"
        when .system?    then "user"
        when .tool?      then "function"
        else                  role.to_s.downcase
        end
      end

      # Dispatches a message to its part-list shape (tool call / tool result / plain).
      def format_parts(msg : Message) : Array(JSON::Any)
        if msg.tool_call?
          format_tool_call(msg)
        elsif msg.tool_result?
          format_tool_result(msg)
        else
          Media.format_content(msg.content)
        end
      end

      private def require_model_id : String
        @model_id || raise Error.new("Gemini completion_url/stream_url requires render_payload to set the model first")
      end

      # Collapses consecutive tool-result messages into one `function` content entry
      # (Gemini groups parallel tool responses). Ported from chat.rb#MessageFormatter.
      class MessageFormatter
        def initialize(@provider : Gemini, @messages : Array(Message))
          @index = 0
          @tool_call_names = {} of String => String
        end

        def format : Array(JSON::Any)
          formatted = [] of JSON::Any

          while current = current_message
            if tool_message?(current)
              tool_parts, next_index = collect_tool_parts
              formatted << build_tool_response(tool_parts)
              @index = next_index
            else
              remember_tool_calls(current) if current.tool_call?
              formatted << build_standard_message(current)
              @index += 1
            end
          end

          formatted
        end

        private def current_message : Message?
          @messages[@index]?
        end

        private def tool_message?(message : Message?) : Bool
          !message.nil? && message.role.tool?
        end

        private def collect_tool_parts : Tuple(Array(JSON::Any), Int32)
          parts = [] of JSON::Any
          index = @index

          while tool_message?(@messages[index]?)
            tool_message = @messages[index]
            tool_name = tool_message.tool_call_id.try { |id| @tool_call_names.delete(id) }
            @provider.format_tool_result(tool_message, tool_name).each { |part| parts << part }
            index += 1
          end

          {parts, index}
        end

        private def build_tool_response(parts : Array(JSON::Any)) : JSON::Any
          JSON::Any.new({
            "role"  => JSON::Any.new("function"),
            "parts" => JSON::Any.new(parts),
          } of String => JSON::Any)
        end

        private def remember_tool_calls(message : Message) : Nil
          message.tool_calls.try &.each do |tool_call_id, tool_call|
            @tool_call_names[tool_call_id] = tool_call.name
          end
        end

        private def build_standard_message(message : Message) : JSON::Any
          JSON::Any.new({
            "role"  => JSON::Any.new(@provider.format_role(message.role)),
            "parts" => JSON::Any.new(@provider.format_parts(message)),
          } of String => JSON::Any)
        end
      end
    end
  end
end
