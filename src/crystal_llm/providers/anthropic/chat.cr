# ported from lib/ruby_llm/providers/anthropic/chat.rb @ ruby_llm 1.15.0
#
# The Anthropic Messages API request/response surface.
#
# Divergences:
# - `render_payload` matches the completion pipeline's hook signature, including
#   `tool_prefs`. When tools are present and either `choice` or `calls` is set, it
#   emits `tool_choice` via `Tools.build_tool_choice(choice, calls)` —
#   `{type: auto|none|any|tool, name?, disable_parallel_tool_use?}` (`calls == "one"`
#   sets the disable flag). It returns `Hash(String, JSON::Any)`.
# - System messages are partitioned out and rendered as a top-level `system` array of
#   text content blocks (Anthropic's shape); chat messages become content-block
#   messages. `max_tokens` defaults to `model.max_tokens || 4096`.
# - `schema` is a `JSON::Any?` envelope; `build_output_config` strips `strict` and
#   wraps the inner schema in `{format: {type:"json_schema", schema: ...}}` (Anthropic
#   structured-output shape), reading with `as_h?`/`dig?` rather than symbol keys.
# - `thinking` is a `Thinking::Config?`; `build_thinking_payload` reads `.budget`.
#   When enabled but no budget is set it raises (ruby_llm parity).
# - Thinking round-trip is wired: thinking text + signature are extracted from
#   response content blocks and attached to the Message (`Thinking.build`); on the
#   outbound side, `format_message` prepends a `thinking`/`redacted_thinking` block
#   to assistant messages that carry a thinking signature when thinking is enabled
#   (multi-turn extended thinking). thinking_tokens are wired too.
# - `response.body` is a raw String (Crest); JSON.parse it here.
require "json"
require "../anthropic"

module CrystalLLM
  module Providers
    class Anthropic < Provider
      def completion_url : String
        "v1/messages"
      end

      def render_payload(messages : Array(Message), tools : Hash(String, Tool),
                         temperature : Float64?, model : Model::Info,
                         stream : Bool = false, schema : JSON::Any? = nil,
                         thinking : Thinking::Config? = nil,
                         tool_prefs : Hash(String, String?)? = nil) : Hash(String, JSON::Any)
        system_messages, chat_messages = separate_messages(messages)
        system_content = build_system_content(system_messages)

        payload = build_base_payload(chat_messages, model, stream, thinking)
        add_optional_fields(payload, system_content, tools, temperature, schema, tool_prefs)
        payload
      end

      # Partition into [system_messages, chat_messages].
      def separate_messages(messages : Array(Message)) : Tuple(Array(Message), Array(Message))
        system_messages = [] of Message
        chat_messages = [] of Message
        messages.each do |msg|
          if msg.role.system?
            system_messages << msg
          else
            chat_messages << msg
          end
        end
        {system_messages, chat_messages}
      end

      # The top-level `system` array: each :system message contributes its content
      # block(s) (an array of `{type:"text", text:...}` blocks, or a Raw value).
      def build_system_content(system_messages : Array(Message)) : Array(JSON::Any)
        blocks = [] of JSON::Any
        system_messages.each do |msg|
          content = msg.content
          formatted = if content.is_a?(Content::Raw)
                        content.value
                      else
                        Media.format_content(content)
                      end
          if arr = formatted.as_a?
            blocks.concat(arr)
          else
            blocks << formatted
          end
        end
        blocks
      end

      def build_base_payload(chat_messages : Array(Message), model : Model::Info,
                             stream : Bool, thinking : Thinking::Config?) : Hash(String, JSON::Any)
        payload = {
          "model"      => JSON::Any.new(model.id),
          "messages"   => JSON::Any.new(chat_messages.map { |msg| format_message(msg, thinking) }),
          "stream"     => JSON::Any.new(stream),
          "max_tokens" => JSON::Any.new((model.max_tokens || 4096).to_i64),
        } of String => JSON::Any

        if thinking_payload = build_thinking_payload(thinking)
          payload["thinking"] = thinking_payload
        end

        payload
      end

      def add_optional_fields(payload : Hash(String, JSON::Any),
                              system_content : Array(JSON::Any), tools : Hash(String, Tool),
                              temperature : Float64?, schema : JSON::Any?,
                              tool_prefs : Hash(String, String?)? = nil) : Nil
        prefs = tool_prefs || {} of String => String?
        unless tools.empty?
          payload["tools"] = JSON::Any.new(tools.map { |_, tool| Tools.function_for(tool) })
          choice = prefs["choice"]?
          calls = prefs["calls"]?
          unless choice.nil? && calls.nil?
            payload["tool_choice"] = Tools.build_tool_choice(choice, calls)
          end
        end
        payload["system"] = JSON::Any.new(system_content) unless system_content.empty?
        payload["temperature"] = JSON::Any.new(temperature) unless temperature.nil?
        if schema && (output_config = build_output_config(schema))
          payload["output_config"] = output_config
        end
      end

      # Anthropic structured-output: `{format: {type:"json_schema", schema: <inner>}}`
      # with `strict` stripped. The `schema` envelope is `{name, schema, strict}`.
      def build_output_config(schema : JSON::Any) : JSON::Any?
        envelope = schema.as_h?
        return nil unless envelope

        inner = envelope["schema"]?.try(&.as_h?)
        normalized = (inner || envelope).dup
        normalized.delete("strict")

        JSON::Any.new({
          "format" => JSON::Any.new({
            "type"   => JSON::Any.new("json_schema"),
            "schema" => JSON::Any.new(normalized),
          } of String => JSON::Any),
        } of String => JSON::Any)
      end

      def parse_completion_response(response : Crest::Response) : Message
        body = response.body
        raise Error.new(response, "Empty response from Anthropic") if body.empty?

        data = JSON.parse(body)

        if msg = data.dig?("error", "message").try(&.as_s?)
          raise Error.new(response, msg)
        end

        content_blocks = data["content"]?.try(&.as_a?) || [] of JSON::Any

        text_content = extract_text_content(content_blocks)
        thinking_content = extract_thinking_content(content_blocks)
        thinking_signature = extract_thinking_signature(content_blocks)
        tool_use_blocks = Tools.find_tool_uses(content_blocks)

        build_message(data, text_content, thinking_content, thinking_signature, tool_use_blocks, response)
      end

      def extract_text_content(blocks : Array(JSON::Any)) : String?
        text = String.build do |io|
          blocks.each do |block_any|
            block = block_any.as_h? || next
            next unless block["type"]?.try(&.as_s?) == "text"
            io << (block["text"]?.try(&.as_s?) || "")
          end
        end
        text.empty? ? nil : text
      end

      def extract_thinking_content(blocks : Array(JSON::Any)) : String?
        thoughts = String.build do |io|
          blocks.each do |block_any|
            block = block_any.as_h? || next
            next unless block["type"]?.try(&.as_s?) == "thinking"
            io << (block["thinking"]?.try(&.as_s?) || block["text"]?.try(&.as_s?) || "")
          end
        end
        thoughts.empty? ? nil : thoughts
      end

      def extract_thinking_signature(blocks : Array(JSON::Any)) : String?
        thinking_block = blocks.find do |block_any|
          (h = block_any.as_h?) && h["type"]?.try(&.as_s?) == "thinking"
        end
        thinking_block ||= blocks.find do |block_any|
          (h = block_any.as_h?) && h["type"]?.try(&.as_s?) == "redacted_thinking"
        end
        return nil unless thinking_block
        h = thinking_block.as_h?
        return nil unless h
        h["signature"]?.try(&.as_s?) || h["data"]?.try(&.as_s?)
      end

      def build_message(data : JSON::Any, content : String?,
                        thinking : String?, thinking_signature : String?,
                        tool_use_blocks : Array(JSON::Any), response : Crest::Response) : Message
        usage = data["usage"]?.try(&.as_h?) || {} of String => JSON::Any

        cached_tokens = int_at(usage["cache_read_input_tokens"]?)
        cache_creation_tokens = int_at(usage["cache_creation_input_tokens"]?)
        if cache_creation_tokens.nil?
          if breakdown = usage["cache_creation"]?.try(&.as_h?)
            cache_creation_tokens = sum_values(breakdown)
          end
        end

        Message.new(
          role: Role::Assistant,
          content: content,
          thinking: Thinking.build(text: thinking, signature: thinking_signature),
          tool_calls: Tools.parse_tool_calls(JSON::Any.new(tool_use_blocks)),
          input_tokens: int_at(usage["input_tokens"]?),
          output_tokens: int_at(usage["output_tokens"]?),
          cached_tokens: cached_tokens,
          cache_creation_tokens: cache_creation_tokens,
          thinking_tokens: extract_thinking_tokens(usage),
          model_id: data["model"]?.try(&.as_s?),
          raw: data
        )
      end

      private def extract_thinking_tokens(usage : Hash(String, JSON::Any)) : Int32?
        if details = usage["output_tokens_details"]?.try(&.as_h?)
          if t = int_at(details["thinking_tokens"]?) || int_at(details["reasoning_tokens"]?)
            return t
          end
        end
        int_at(usage["thinking_tokens"]?) || int_at(usage["reasoning_tokens"]?)
      end

      private def sum_values(hash : Hash(String, JSON::Any)) : Int32?
        total = 0
        seen = false
        hash.each_value do |v|
          if n = int_at(v)
            total += n
            seen = true
          end
        end
        seen ? total : nil
      end

      # ---- Message formatting ----

      def format_messages(messages : Array(Message)) : Array(JSON::Any)
        messages.map { |msg| format_message(msg, nil) }
      end

      # Formats one message into an Anthropic content-block message. When thinking
      # is enabled, an assistant message that carries a thinking signature gets a
      # leading `thinking`/`redacted_thinking` block (multi-turn extended thinking).
      def format_message(msg : Message, thinking : Thinking::Config?) : JSON::Any
        thinking_enabled = thinking.try(&.enabled?) || false

        if msg.tool_call?
          format_tool_call_message(msg, thinking_enabled)
        elsif msg.tool_result?
          Tools.format_tool_result(msg)
        else
          format_basic_message(msg, thinking_enabled)
        end
      end

      private def format_basic_message(msg : Message, thinking_enabled : Bool) : JSON::Any
        content_blocks = [] of JSON::Any
        if msg.role.assistant? && thinking_enabled
          if block = build_thinking_block(msg.thinking)
            content_blocks << block
          end
        end
        append_formatted_content(content_blocks, msg.content)

        JSON::Any.new({
          "role"    => JSON::Any.new(convert_role(msg.role)),
          "content" => JSON::Any.new(content_blocks),
        } of String => JSON::Any)
      end

      private def format_tool_call_message(msg : Message, thinking_enabled : Bool) : JSON::Any
        content = msg.content
        if content.is_a?(Content::Raw)
          value = content.value
          blocks = value.as_a? || [value]
          blocks = prepend_thinking_block(blocks, msg, thinking_enabled)
          return JSON::Any.new({
            "role"    => JSON::Any.new("assistant"),
            "content" => JSON::Any.new(blocks),
          } of String => JSON::Any)
        end

        content_blocks = prepend_thinking_block([] of JSON::Any, msg, thinking_enabled)
        text = content.is_a?(String) ? content : content.try(&.to_s)
        content_blocks << Media.format_text(text) if text && !text.empty?

        if calls = msg.tool_calls
          calls.each_value do |tool_call|
            content_blocks << Tools.format_tool_use_block(tool_call)
          end
        end

        JSON::Any.new({
          "role"    => JSON::Any.new("assistant"),
          "content" => JSON::Any.new(content_blocks),
        } of String => JSON::Any)
      end

      # Unshifts a thinking block onto `content_blocks` when thinking is enabled and
      # the message carries thinking. Mirrors ruby_llm's `prepend_thinking_block`.
      private def prepend_thinking_block(content_blocks : Array(JSON::Any), msg : Message,
                                         thinking_enabled : Bool) : Array(JSON::Any)
        return content_blocks unless thinking_enabled
        if block = build_thinking_block(msg.thinking)
          content_blocks.unshift(block)
        end
        content_blocks
      end

      # A `thinking` block (text + optional signature) or a `redacted_thinking` block
      # (signature only). Returns nil when there is no thinking to send.
      private def build_thinking_block(thinking : Thinking?) : JSON::Any?
        return nil unless thinking

        if text = thinking.text
          block = {
            "type"     => JSON::Any.new("thinking"),
            "thinking" => JSON::Any.new(text),
          } of String => JSON::Any
          if sig = thinking.signature
            block["signature"] = JSON::Any.new(sig)
          end
          JSON::Any.new(block)
        elsif sig = thinking.signature
          JSON::Any.new({
            "type" => JSON::Any.new("redacted_thinking"),
            "data" => JSON::Any.new(sig),
          } of String => JSON::Any)
        end
      end

      private def append_formatted_content(content_blocks : Array(JSON::Any),
                                           content : String | Content | Nil) : Nil
        formatted = Media.format_content(content)
        if arr = formatted.as_a?
          content_blocks.concat(arr)
        else
          content_blocks << formatted
        end
      end

      # tool/user -> "user", everything else -> "assistant".
      def convert_role(role : Role) : String
        case role
        when .tool?, .user? then "user"
        else                     "assistant"
        end
      end

      # `{type:"enabled", budget_tokens: n}` when thinking is enabled with a budget.
      # Raises when enabled but no budget is set (ruby_llm parity).
      def build_thinking_payload(thinking : Thinking::Config?) : JSON::Any?
        return nil unless thinking && thinking.enabled?

        budget = thinking.budget
        raise ArgumentError.new("Anthropic thinking requires a budget") if budget.nil?

        JSON::Any.new({
          "type"          => JSON::Any.new("enabled"),
          "budget_tokens" => JSON::Any.new(budget.to_i64),
        } of String => JSON::Any)
      end

      # Coerce a JSON::Any numeric to Int32 (token counts).
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
