# ported from lib/ruby_llm/providers/mistral/chat.rb @ ruby_llm 1.15.0
#
# Mistral's chat request/response surface. It is OpenAI-compatible, so this only
# overrides the spots where Mistral diverges from the OpenAI port:
#  - `format_role`: Mistral wants the bare downcased role string for every role
#    (OpenAI maps :system -> "developer"/"system"; Mistral always uses "system").
#  - `render_payload`: drop OpenAI's `stream_options`, apply Mistral thinking
#    payload shaping, and normalize a "required" tool_choice into a named-function
#    object when exactly one tool is present.
#  - `build_tool_choice`: ":required" maps to Mistral's "any" sentinel.
#
# Divergences / deferrals:
# - Assistant thinking *blocks* in format_messages (`format_content_with_thinking` /
#   `build_thinking_blocks`) read `msg.thinking` and are PORTED: an assistant message
#   with thinking gets a leading `{type: thinking, thinking: [{type: text, text}],
#   signature}` content block (or a signature-only thinking block). This overrides
#   the OpenAI base `format_messages` so Mistral emits its thinking-block shape rather
#   than OpenAI's `reasoning`/`reasoning_content` keys. Inbound thinking is handled by
#   the inherited OpenAI `parse_completion_response` (content-block extraction), which
#   matches ruby_llm (Mistral does not override it). The thinking-*payload* shaping
#   (reasoning_effort / prompt_mode / reasoning) operates on `Thinking::Config` and
#   IS ported.
# - `tool_choice` is sourced from a `tool_choice` payload key written by the chat/
#   agent layer (tool_prefs), which is itself deferred from render_payload (see
#   provider_completion.cr). `normalize_required_tool_choice` is ported so it runs
#   if/when a "tool_choice" key is present in the merged payload.
# - `warn_on_unsupported_thinking` logs via CrystalLLM.logger in ruby_llm; the
#   top-level logger is deferred (PORTING.md), so the unsupported-thinking branch
#   silently drops reasoning_effort here (no warn). Documented divergence.
require "json"
require "../mistral"

module CrystalLLM
  module Providers
    class Mistral < OpenAI
      # Mistral uses the bare downcased role for every role (no developer mapping).
      def format_role(role : Role) : String
        role.to_s.downcase
      end

      # Overrides OpenAI's `format_messages` so assistant thinking is emitted as
      # Mistral thinking content blocks (not OpenAI's `reasoning` keys).
      def format_messages(messages : Array(Message)) : Array(JSON::Any)
        messages.map do |msg|
          entry = {} of String => JSON::Any
          entry["role"] = JSON::Any.new(format_role(msg.role))
          entry["content"] = format_content_with_thinking(msg)
          if formatted = format_tool_calls(msg.tool_calls)
            entry["tool_calls"] = formatted
          end
          if id = msg.tool_call_id
            entry["tool_call_id"] = JSON::Any.new(id)
          end
          JSON::Any.new(entry)
        end
      end

      # The content wire value, with a leading thinking block prepended when an
      # assistant message carries thinking. Mirrors ruby_llm's
      # `format_content_with_thinking` (+ `build_thinking_blocks`).
      def format_content_with_thinking(msg : Message) : JSON::Any
        formatted = Media.format_content(msg.content)
        thinking = msg.thinking
        return formatted unless msg.role.assistant? && thinking

        blocks = build_thinking_blocks(thinking)
        append_formatted_content(blocks, formatted)
        JSON::Any.new(blocks)
      end

      # A Mistral thinking content block: text -> `{type: thinking, thinking: [{type:
      # text, text}], signature?}`; signature-only -> `{type: thinking, signature}`.
      private def build_thinking_blocks(thinking : Thinking) : Array(JSON::Any)
        if text = thinking.text
          block = {
            "type"     => JSON::Any.new("thinking"),
            "thinking" => JSON::Any.new([
              JSON::Any.new({
                "type" => JSON::Any.new("text"),
                "text" => JSON::Any.new(text),
              } of String => JSON::Any),
            ]),
          } of String => JSON::Any
          if sig = thinking.signature
            block["signature"] = JSON::Any.new(sig)
          end
          [JSON::Any.new(block)]
        elsif sig = thinking.signature
          [JSON::Any.new({
            "type"      => JSON::Any.new("thinking"),
            "signature" => JSON::Any.new(sig),
          } of String => JSON::Any)]
        else
          [] of JSON::Any
        end
      end

      # Appends the formatted content onto the thinking blocks: an array of parts is
      # concatenated; a non-null scalar becomes a `{type: text, text}` block.
      private def append_formatted_content(blocks : Array(JSON::Any), formatted : JSON::Any) : Nil
        if arr = formatted.as_a?
          blocks.concat(arr)
        elsif !formatted.raw.nil?
          if s = formatted.as_s?
            blocks << JSON::Any.new({
              "type" => JSON::Any.new("text"),
              "text" => JSON::Any.new(s),
            } of String => JSON::Any)
          else
            blocks << formatted
          end
        end
      end

      def render_payload(messages : Array(Message), tools : Hash(String, Tool),
                         temperature : Float64?, model : Model::Info,
                         stream : Bool = false, schema : JSON::Any? = nil,
                         thinking : Thinking::Config? = nil) : Hash(String, JSON::Any)
        payload = super
        payload.delete("stream_options")
        configure_thinking_payload(payload, model, thinking)
        normalize_required_tool_choice(payload)
        payload
      end

      # ":required" becomes Mistral's "any" sentinel; everything else defers to the
      # OpenAI tool_choice shaping.
      def build_tool_choice(tool_choice : String) : JSON::Any
        return JSON::Any.new("any") if tool_choice == "required"

        super
      end

      # When tool_choice is "any" and exactly one tool is offered, Mistral wants a
      # concrete named-function tool_choice object instead of the "any" sentinel.
      def normalize_required_tool_choice(payload : Hash(String, JSON::Any)) : Nil
        return unless payload["tool_choice"]?.try(&.as_s?) == "any"

        tools = payload["tools"]?.try(&.as_a?)
        return unless tools && tools.size == 1

        function_name = tools[0].dig?("function", "name").try(&.as_s?)
        return unless function_name

        payload["tool_choice"] = JSON::Any.new({
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new({"name" => JSON::Any.new(function_name)} of String => JSON::Any),
        } of String => JSON::Any)
      end

      # ---- thinking payload shaping (operates on Thinking::Config) ----

      def configure_thinking_payload(payload : Hash(String, JSON::Any), model : Model::Info,
                                     thinking : Thinking::Config?) : Nil
        return unless thinking && thinking.enabled?

        model_id = model.id || ""
        if native_reasoning_model?(model_id)
          configure_native_reasoning_payload(payload, thinking)
        elsif adjustable_reasoning_model?(model_id)
          payload["reasoning_effort"] = JSON::Any.new(reasoning_effort_for(thinking))
        else
          # Unsupported model: drop reasoning_effort. ruby_llm also warns via
          # CrystalLLM.logger (deferred — see file header).
          payload.delete("reasoning_effort")
        end
      end

      def configure_native_reasoning_payload(payload : Hash(String, JSON::Any),
                                             thinking : Thinking::Config) : Nil
        payload.delete("reasoning_effort")
        if thinking.effort == "none"
          payload["prompt_mode"] = JSON::Any.new(nil)
        else
          payload["prompt_mode"] = JSON::Any.new("reasoning")
        end
      end

      def reasoning_effort_for(thinking : Thinking::Config) : String
        effort = thinking.effort
        return effort if effort && (effort == "high" || effort == "none")

        "high"
      end

      def native_reasoning_model?(model_id : String) : Bool
        model_id.includes?("magistral")
      end

      def adjustable_reasoning_model?(model_id : String) : Bool
        model_id.matches?(/\Amistral-(?:small-latest|medium-(?:3(?:[.-]5)?|latest))\z/)
      end
    end
  end
end
