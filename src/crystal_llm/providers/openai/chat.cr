# ported from lib/ruby_llm/providers/openai/chat.rb @ ruby_llm 1.15.0
#
# The OpenAI chat completions request/response surface.
#
# Divergences:
# - `render_payload` matches the completion pipeline's hook signature (no `tool_prefs`;
#   deferred — see provider_completion.cr). It returns `Hash(String, JSON::Any)`.
# - `schema` is a `JSON::Any?` (the envelope `{name, schema, strict}` from the chat
#   layer), read with `as_h?`/`dig?` rather than Ruby symbol keys.
# - `thinking` is a `Thinking::Config?`; `resolve_effort` reads `.effort` (the
#   `respond_to?(:effort)` branch — Crystal's Config always responds).
# - Thinking text/signature extraction into Message IS wired: `thinking` content
#   blocks (or `reasoning_content`/`reasoning`/`thinking` keys) become the thinking
#   text, `reasoning_signature`/`signature` the signature, attached via
#   `Thinking.build`. Outbound, `format_thinking` re-emits reasoning on assistant
#   messages. reasoning_tokens are wired; `<think>`-tag content stripping is ported.
#   This is the shared inbound/outbound thinking path for Mistral too (it inherits
#   `parse_completion_response`/`format_messages` from here).
# - `response.body` is the raw String (Crest), so parse_completion_response JSON.parses
#   it (ruby_llm's Faraday json middleware pre-parses; here we parse in-method).
require "json"
require "../openai"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      def completion_url : String
        "chat/completions"
      end

      def render_payload(messages : Array(Message), tools : Hash(String, Tool),
                         temperature : Float64?, model : Model::Info,
                         stream : Bool = false, schema : JSON::Any? = nil,
                         thinking : Thinking::Config? = nil) : Hash(String, JSON::Any)
        payload = {
          "model"    => JSON::Any.new(model.id),
          "messages" => JSON::Any.new(format_messages(messages)),
          "stream"   => JSON::Any.new(stream),
        } of String => JSON::Any

        payload["temperature"] = JSON::Any.new(temperature) unless temperature.nil?

        unless tools.empty?
          payload["tools"] = JSON::Any.new(tools.map { |_, tool| tool_for(tool) })
        end

        if schema && (schema_hash = schema.as_h?)
          json_schema = {
            "name"   => schema_hash["name"]? || JSON::Any.new(nil),
            "schema" => schema_hash["schema"]? || JSON::Any.new(nil),
            "strict" => schema_hash["strict"]? || JSON::Any.new(nil),
          } of String => JSON::Any
          payload["response_format"] = JSON::Any.new({
            "type"        => JSON::Any.new("json_schema"),
            "json_schema" => JSON::Any.new(json_schema),
          } of String => JSON::Any)
        end

        if effort = resolve_effort(thinking)
          payload["reasoning_effort"] = JSON::Any.new(effort)
        end

        if stream
          payload["stream_options"] = JSON::Any.new({"include_usage" => JSON::Any.new(true)} of String => JSON::Any)
        end

        payload
      end

      def parse_completion_response(response : Crest::Response) : Message
        body = response.body
        raise Error.new(response, "Empty response from OpenAI") if body.empty?

        data = JSON.parse(body)

        if msg = data.dig?("error", "message").try(&.as_s?)
          raise Error.new(response, msg)
        end

        message_data = data.dig?("choices", 0, "message").try(&.as_h?)
        raise Error.new(response, "OpenAI response had no message") unless message_data

        usage = data["usage"]?.try(&.as_h?) || {} of String => JSON::Any
        content, thinking_from_blocks = extract_content_and_thinking(message_data["content"]?)
        thinking_text = thinking_from_blocks || extract_thinking_text(message_data)
        thinking_signature = extract_thinking_signature(message_data)

        Message.new(
          role: Role::Assistant,
          content: content,
          thinking: Thinking.build(text: thinking_text, signature: thinking_signature),
          tool_calls: parse_tool_calls(message_data["tool_calls"]?),
          input_tokens: input_tokens(usage),
          output_tokens: output_tokens(usage),
          cached_tokens: cache_read_tokens(usage),
          cache_creation_tokens: cache_write_tokens(usage),
          thinking_tokens: thinking_tokens(usage),
          model_id: data["model"]?.try(&.as_s?),
          raw: data
        )
      end

      # ---- Token accounting (ported from chat.rb) ----

      def input_tokens(usage : Hash(String, JSON::Any)) : Int32?
        if miss = int_at(usage["prompt_cache_miss_tokens"]?)
          return miss
        end

        prompt_tokens = int_at(usage["prompt_tokens"]?)
        return nil unless prompt_tokens

        {prompt_tokens - (cache_read_tokens(usage) || 0) - (cache_write_tokens(usage) || 0), 0}.max
      end

      def output_tokens(usage : Hash(String, JSON::Any)) : Int32?
        completion_tokens = int_at(usage["completion_tokens"]?)
        return nil unless completion_tokens

        generated = generated_tokens_from_total(usage)
        return completion_tokens unless generated && generated > completion_tokens

        generated
      end

      def generated_tokens_from_total(usage : Hash(String, JSON::Any)) : Int32?
        prompt_tokens = int_at(usage["prompt_tokens"]?)
        total_tokens = int_at(usage["total_tokens"]?)
        return nil unless prompt_tokens && total_tokens

        {total_tokens - prompt_tokens, 0}.max
      end

      def cache_read_tokens(usage : Hash(String, JSON::Any)) : Int32?
        if details = usage["prompt_tokens_details"]?.try(&.as_h?)
          if cached = int_at(details["cached_tokens"]?)
            return cached
          end
        end
        int_at(usage["prompt_cache_hit_tokens"]?)
      end

      def cache_write_tokens(usage : Hash(String, JSON::Any)) : Int32?
        if details = usage["prompt_tokens_details"]?.try(&.as_h?)
          if written = int_at(details["cache_write_tokens"]?)
            return written
          end
        end
        0
      end

      def thinking_tokens(usage : Hash(String, JSON::Any)) : Int32?
        if details = usage["completion_tokens_details"]?.try(&.as_h?)
          if reasoning = int_at(details["reasoning_tokens"]?)
            return reasoning
          end
        end
        int_at(usage["reasoning_tokens"]?)
      end

      # ---- Message formatting ----

      def format_messages(messages : Array(Message)) : Array(JSON::Any)
        messages.map do |msg|
          entry = {} of String => JSON::Any
          entry["role"] = JSON::Any.new(format_role(msg.role))
          entry["content"] = Media.format_content(format_content_arg(msg.content))
          if formatted = format_tool_calls(msg.tool_calls)
            entry["tool_calls"] = formatted
          end
          if id = msg.tool_call_id
            entry["tool_call_id"] = JSON::Any.new(id)
          end
          format_thinking(msg).each { |k, v| entry[k] = v }
          JSON::Any.new(entry)
        end
      end

      # Re-emits an assistant message's reasoning so a multi-turn request can carry
      # prior thinking. Mirrors ruby_llm's `format_thinking`: `reasoning` +
      # `reasoning_content` (text) and `reasoning_signature` (signature). Returns an
      # empty hash when there is no thinking to send.
      def format_thinking(msg : Message) : Hash(String, JSON::Any)
        result = {} of String => JSON::Any
        return result unless msg.role.assistant?

        thinking = msg.thinking
        return result unless thinking

        if text = thinking.text
          result["reasoning"] = JSON::Any.new(text)
          result["reasoning_content"] = JSON::Any.new(text)
        end
        if sig = thinking.signature
          result["reasoning_signature"] = JSON::Any.new(sig)
        end
        result
      end

      private def format_content_arg(content : String | Content | Nil) : String | Content | Content::Raw | Nil
        content
      end

      def format_role(role : Role) : String
        case role
        when .system?
          @config.openai_use_system_role ? "system" : "developer"
        else
          role.to_s.downcase
        end
      end

      def resolve_effort(thinking : Thinking::Config?) : String?
        return nil unless thinking
        thinking.effort
      end

      # ---- content / thinking extraction ----

      # Top-level reasoning text on a message object: `reasoning_content` /
      # `reasoning` / `thinking` (first String wins). Used when the content blocks
      # carry no thinking. Mirrors ruby_llm's `extract_thinking_text`.
      def extract_thinking_text(message_data : Hash(String, JSON::Any)) : String?
        candidate = message_data["reasoning_content"]? ||
                    message_data["reasoning"]? ||
                    message_data["thinking"]?
        candidate.try(&.as_s?)
      end

      # The reasoning signature: `reasoning_signature` / `signature` (first String
      # wins). Mirrors ruby_llm's `extract_thinking_signature`.
      def extract_thinking_signature(message_data : Hash(String, JSON::Any)) : String?
        candidate = message_data["reasoning_signature"]? || message_data["signature"]?
        candidate.try(&.as_s?)
      end

      # Returns {content, thinking_text}. Array content (content blocks) collapses
      # to joined text + joined thinking; String content runs <think>-tag stripping.
      def extract_content_and_thinking(content : JSON::Any?) : Tuple(String?, String?)
        return {nil, nil} if content.nil?

        if str = content.as_s?
          return extract_think_tag_content(str)
        end

        blocks = content.as_a?
        return {content_to_s(content), nil} unless blocks

        text = extract_text_from_blocks(blocks)
        thinking = extract_thinking_from_blocks(blocks)
        {text.empty? ? nil : text, thinking.empty? ? nil : thinking}
      end

      private def content_to_s(content : JSON::Any) : String?
        content.as_s? || (content.raw.nil? ? nil : content.to_json)
      end

      private def extract_text_from_blocks(blocks : Array(JSON::Any)) : String
        String.build do |io|
          blocks.each do |block_any|
            block = block_any.as_h? || next
            next unless block["type"]?.try(&.as_s?) == "text"
            if t = block["text"]?.try(&.as_s?)
              io << t
            end
          end
        end
      end

      private def extract_thinking_from_blocks(blocks : Array(JSON::Any)) : String
        String.build do |io|
          blocks.each do |block_any|
            block = block_any.as_h? || next
            next unless block["type"]?.try(&.as_s?) == "thinking"
            io << extract_thinking_text_from_block(block)
          end
        end
      end

      private def extract_thinking_text_from_block(block : Hash(String, JSON::Any)) : String
        thinking_block = block["thinking"]?
        if thinking_block
          if s = thinking_block.as_s?
            return s
          end
          if arr = thinking_block.as_a?
            return String.build do |io|
              arr.each do |item_any|
                item = item_any.as_h? || next
                next unless item["type"]?.try(&.as_s?) == "text"
                io << (item["text"]?.try(&.as_s?) || "")
              end
            end
          end
        end
        block["text"]?.try(&.as_s?) || ""
      end

      # Splits <think>...</think> out of a content string. Returns {content, thinking}.
      def extract_think_tag_content(text : String) : Tuple(String?, String?)
        return {text, nil} unless text.includes?("<think>")

        thinking = text.scan(/<think>(.*?)<\/think>/m).map { |match| match[1] }.join
        content = text.gsub(/<think>.*?<\/think>/m, "").strip

        {content.empty? ? nil : content, thinking.empty? ? nil : thinking}
      end

      # Coerce a JSON::Any numeric to Int32 (OpenAI token counts).
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
