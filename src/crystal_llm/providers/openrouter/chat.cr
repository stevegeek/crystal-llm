# ported from lib/ruby_llm/providers/openrouter/chat.rb @ ruby_llm 1.15.0
#
# OpenRouter's chat request surface. The only material divergence from OpenAI's
# render_payload is the thinking config: OpenRouter takes a `reasoning` *object*
# (`{effort:, max_tokens:, enabled:}`) rather than OpenAI's flat `reasoning_effort`
# string. Token accounting, parse_completion_response, format_messages/format_role,
# and build_chunk are inherited unchanged from OpenAI (identical wire shapes).
#
# Divergences from ruby_llm's openrouter/chat.rb:
# - matches the completion pipeline hook signature (no `tool_prefs`/`tool_choice`/
#   `parallel_tool_calls` — deferred, see provider_completion.cr). Returns
#   `Hash(String, JSON::Any)`.
# - `schema` is a `JSON::Any?` envelope (`{name, schema, strict}`); ruby_llm deep-dups
#   the schema and deletes a nested `strict` before re-wrapping. The port copies the
#   schema map and drops a top-level "strict" key the same way.
# - `build_reasoning` reads a `Thinking::Config` (`.effort`/`.budget`); Crystal's
#   Config always responds, so the Ruby `respond_to?` guards collapse to nil-checks.
# - thinking text/signature extraction into the Message IS wired here. OpenRouter's
#   reasoning shape differs from OpenAI's: a message carries either a `reasoning`
#   String or a `reasoning_details` array (`reasoning.text`/`reasoning.summary`/
#   `reasoning.encrypted` entries). This file overrides `parse_completion_response`
#   (to read that shape) and `format_thinking` (to re-emit `reasoning_details` on
#   outbound assistant messages, via the inherited OpenAI `format_messages`).
require "json"
require "../openai"
require "../openrouter"

module CrystalLLM
  module Providers
    class OpenRouter < OpenAI
      def render_payload(messages : Array(Message), tools : Hash(String, Tool),
                         temperature : Float64?, model : Model::Info,
                         stream : Bool = false, schema : JSON::Any? = nil,
                         thinking : Thinking::Config? = nil,
                         tool_prefs : Hash(String, String?)? = nil) : Hash(String, JSON::Any)
        prefs = tool_prefs || {} of String => String?
        payload = {
          "model"    => JSON::Any.new(model.id),
          "messages" => JSON::Any.new(format_messages(messages)),
          "stream"   => JSON::Any.new(stream),
        } of String => JSON::Any

        payload["temperature"] = JSON::Any.new(temperature) unless temperature.nil?

        unless tools.empty?
          payload["tools"] = JSON::Any.new(tools.map { |_, tool| tool_for(tool) })
          if choice = prefs["choice"]?
            payload["tool_choice"] = build_tool_choice(choice)
          end
          unless (calls = prefs["calls"]?).nil?
            payload["parallel_tool_calls"] = JSON::Any.new(calls == "many")
          end
        end

        if schema && (schema_hash = schema.as_h?)
          schema_def = schema_hash["schema"]?
          json_schema = {
            "name"   => schema_hash["name"]? || JSON::Any.new(nil),
            "schema" => strip_strict(schema_def),
            "strict" => schema_hash["strict"]? || JSON::Any.new(nil),
          } of String => JSON::Any
          payload["response_format"] = JSON::Any.new({
            "type"        => JSON::Any.new("json_schema"),
            "json_schema" => JSON::Any.new(json_schema),
          } of String => JSON::Any)
        end

        if reasoning = build_reasoning(thinking)
          payload["reasoning"] = reasoning
        end

        if stream
          payload["stream_options"] = JSON::Any.new({"include_usage" => JSON::Any.new(true)} of String => JSON::Any)
        end

        payload
      end

      # ruby_llm deep-dups the schema and deletes a nested `strict` (so the canonical
      # strict flag lives only in the json_schema envelope). Mirrors that by copying
      # the schema map (if it is one) and dropping a top-level "strict" key.
      private def strip_strict(schema_def : JSON::Any?) : JSON::Any
        return JSON::Any.new(nil) if schema_def.nil?
        if h = schema_def.as_h?
          copy = h.dup
          copy.delete("strict")
          return JSON::Any.new(copy)
        end
        schema_def
      end

      # Builds OpenRouter's `reasoning` object from a Thinking::Config, or nil when
      # thinking is disabled. effort/max_tokens map straight through; an enabled
      # config with neither falls back to `{enabled: true}`.
      def build_reasoning(thinking : Thinking::Config?) : JSON::Any?
        return nil unless thinking && thinking.enabled?

        reasoning = {} of String => JSON::Any
        if effort = thinking.effort
          reasoning["effort"] = JSON::Any.new(effort)
        end
        if budget = thinking.budget
          reasoning["max_tokens"] = JSON::Any.new(budget)
        end
        reasoning["enabled"] = JSON::Any.new(true) if reasoning.empty?
        JSON::Any.new(reasoning)
      end

      # ---- inbound thinking extraction (OpenRouter reasoning shape) ----
      #
      # These override the OpenAI base helpers (which the inherited
      # `parse_completion_response` calls), so the round-trip reads OpenRouter's
      # `reasoning` String / `reasoning_details` array rather than OpenAI's
      # `reasoning_content` keys. ruby_llm: openrouter/chat.rb#extract_thinking_*.

      # `reasoning` String wins; otherwise join `reasoning.text`/`reasoning.summary`
      # entries from `reasoning_details`. nil when empty.
      def extract_thinking_text(message_data : Hash(String, JSON::Any)) : String?
        if reasoning = message_data["reasoning"]?.try(&.as_s?)
          return reasoning
        end

        details = message_data["reasoning_details"]?.try(&.as_a?)
        return nil unless details

        text = String.build do |io|
          details.each do |detail_any|
            detail = detail_any.as_h? || next
            case detail["type"]?.try(&.as_s?)
            when "reasoning.text"
              io << (detail["text"]?.try(&.as_s?) || "")
            when "reasoning.summary"
              io << (detail["summary"]?.try(&.as_s?) || "")
            end
          end
        end
        text.empty? ? nil : text
      end

      # The first String `signature` in `reasoning_details`, else the `data` of a
      # `reasoning.encrypted` entry.
      def extract_thinking_signature(message_data : Hash(String, JSON::Any)) : String?
        details = message_data["reasoning_details"]?.try(&.as_a?)
        return nil unless details

        details.each do |detail_any|
          detail = detail_any.as_h? || next
          if sig = detail["signature"]?.try(&.as_s?)
            return sig
          end
        end

        details.each do |detail_any|
          detail = detail_any.as_h? || next
          next unless detail["type"]?.try(&.as_s?) == "reasoning.encrypted"
          if data = detail["data"]?.try(&.as_s?)
            return data
          end
        end
        nil
      end

      # ---- outbound thinking (reasoning_details on assistant messages) ----
      #
      # Overrides OpenAI's `format_thinking` (called by the inherited
      # `format_messages`): OpenRouter re-emits reasoning as a `reasoning_details`
      # array, not the `reasoning`/`reasoning_content` keys. ruby_llm:
      # openrouter/chat.rb#format_thinking.
      def format_thinking(msg : Message) : Hash(String, JSON::Any)
        result = {} of String => JSON::Any
        thinking = msg.thinking
        return result unless thinking && msg.role.assistant?

        details = [] of JSON::Any
        if text = thinking.text
          entry = {
            "type" => JSON::Any.new("reasoning.text"),
            "text" => JSON::Any.new(text),
          } of String => JSON::Any
          if sig = thinking.signature
            entry["signature"] = JSON::Any.new(sig)
          end
          details << JSON::Any.new(entry)
        elsif sig = thinking.signature
          details << JSON::Any.new({
            "type" => JSON::Any.new("reasoning.encrypted"),
            "data" => JSON::Any.new(sig),
          } of String => JSON::Any)
        end

        result["reasoning_details"] = JSON::Any.new(details) unless details.empty?
        result
      end
    end
  end
end
