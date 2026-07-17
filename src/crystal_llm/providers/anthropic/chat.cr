# ported from lib/ruby_llm/providers/anthropic/chat.rb @ ruby_llm 1.16.0
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
#   The resulting hash MERGES into any `output_config` already set by adaptive
#   thinking rather than overwriting it (ruby_llm 3f27b864).
# - `thinking` is a `Thinking::Config?`. `add_thinking_fields`/`build_thinking_payload`
#   consult the model's registry `reasoning_options` (ruby_llm 3f27b864, "Task 6"
#   `Model::Info#reasoning_option`) to choose between legacy budget-based thinking
#   (`{thinking:{type:"enabled",budget_tokens:}}`, gated on the model exposing a
#   `budget_tokens` reasoning option) and adaptive effort-based thinking
#   (`{thinking:{type:"adaptive"},output_config:{effort:}}`, gated on `effort`).
#   `effort == "none"` disables thinking outright. A budget/effort requested on a
#   model that doesn't advertise the matching reasoning option raises `ArgumentError`
#   naming the model id (ruby_llm parity).
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
          formatted = if content.is_a?(CrystalLLM::Content::Raw)
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

        add_thinking_fields(payload, thinking, model)

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
        if schema && (schema_output_config = build_output_config(schema))
          merge_output_config(payload, schema_output_config)
        end
      end

      # `payload[:output_config] = payload.fetch(:output_config, {}).merge(...)` —
      # the schema-driven output_config merges onto (rather than overwrites) any
      # output_config already set by adaptive thinking (ruby_llm 3f27b864).
      private def merge_output_config(payload : Hash(String, JSON::Any), addition : JSON::Any) : Nil
        existing = payload["output_config"]?.try(&.as_h?) || {} of String => JSON::Any
        addition_hash = addition.as_h? || {} of String => JSON::Any
        payload["output_config"] = JSON::Any.new(Utils.deep_merge(existing, addition_hash))
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
        if content.is_a?(CrystalLLM::Content::Raw)
          value = content.value
          blocks = value.as_a? || [value]
          blocks = prepend_thinking_block(blocks, msg, thinking_enabled)
          return JSON::Any.new({
            "role"    => JSON::Any.new("assistant"),
            "content" => JSON::Any.new(blocks),
          } of String => JSON::Any)
        end

        content_blocks = prepend_thinking_block([] of JSON::Any, msg, thinking_enabled)
        # `content` may format to an Array of blocks (text + attachments); concat
        # rather than nest (ruby_llm a6a02653's `append_formatted_content`).
        case content
        when String, CrystalLLM::Content
          append_formatted_content(content_blocks, content) unless content.empty?
        end

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
                                           content : String | CrystalLLM::Content | CrystalLLM::Content::Raw | Nil) : Nil
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

      # Applies `build_thinking_payload`'s `:thinking` fragment onto `payload["thinking"]`
      # and merges its `:output_config` fragment onto `payload["output_config"]` (so a
      # schema-driven output_config set later still combines, not overwrites — see
      # `add_optional_fields`/`merge_output_config`). Mirrors ruby_llm's `add_thinking_fields`.
      def add_thinking_fields(payload : Hash(String, JSON::Any), thinking : Thinking::Config?,
                              model : Model::Info) : Nil
        thinking_payload = build_thinking_payload(thinking, model)
        return unless thinking_payload

        if t = thinking_payload["thinking"]?
          payload["thinking"] = t
        end
        return unless output_config = thinking_payload["output_config"]?

        merge_output_config(payload, output_config)
      end

      # Builds the `{"thinking" => ..., "output_config" => ...}` fragment for a given
      # thinking config + model, or nil when thinking isn't enabled / is disabled via
      # `effort: "none"`. Mirrors ruby_llm's `build_thinking_payload(thinking, model)`
      # (ruby_llm 3f27b864):
      # - A budget on a model with the `budget_tokens` reasoning option ->
      #   `enabled_thinking_payload`; on a model without it -> raises ArgumentError.
      # - Otherwise an effort on a model with the `effort` reasoning option ->
      #   `adaptive_thinking_payload`; on a model without it -> raises ArgumentError.
      # - No budget and no (usable) effort -> raises ArgumentError.
      def build_thinking_payload(thinking : Thinking::Config?, model : Model::Info) : Hash(String, JSON::Any)?
        return nil unless thinking && thinking.enabled?

        effort = resolve_effort(thinking)
        return nil if effort == "none"

        if budget = resolve_budget(thinking)
          return enabled_thinking_payload(budget) if model.reasoning_option("budget_tokens")

          raise ArgumentError.new("Anthropic thinking budget is not supported for #{model.id}")
        end

        raise ArgumentError.new("Anthropic adaptive thinking requires an effort") if effort.nil?
        return adaptive_thinking_payload(effort) if model.reasoning_option("effort")

        raise ArgumentError.new("Anthropic thinking effort is not supported for #{model.id}")
      end

      # `{thinking: {type:"enabled", budget_tokens: n}}`.
      def enabled_thinking_payload(budget : Int32) : Hash(String, JSON::Any)
        {
          "thinking" => JSON::Any.new({
            "type"          => JSON::Any.new("enabled"),
            "budget_tokens" => JSON::Any.new(budget.to_i64),
          } of String => JSON::Any),
        } of String => JSON::Any
      end

      # `{thinking: {type:"adaptive"}, output_config: {effort: <effort>}}`.
      def adaptive_thinking_payload(effort : String) : Hash(String, JSON::Any)
        {
          "thinking"      => JSON::Any.new({"type" => JSON::Any.new("adaptive")} of String => JSON::Any),
          "output_config" => JSON::Any.new({"effort" => JSON::Any.new(effort)} of String => JSON::Any),
        } of String => JSON::Any
      end

      # Blank/nil effort normalizes to nil; anything else (including "none") passes
      # through unchanged. Mirrors ruby_llm's `resolve_effort`.
      def resolve_effort(thinking : Thinking::Config) : String?
        effort = thinking.effort
        effort.nil? || effort.empty? ? nil : effort
      end

      # `Thinking::Config#budget` is already `Int32?` (design §11: no runtime type
      # check needed, unlike ruby_llm's `budget.is_a?(Integer)`). Mirrors ruby_llm's
      # `resolve_budget`.
      def resolve_budget(thinking : Thinking::Config) : Int32?
        thinking.budget
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
