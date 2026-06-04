# ported from lib/ruby_llm/providers/bedrock/streaming.rb @ ruby_llm 1.15.0
#
# Builds a Chunk from one decoded Bedrock ConverseStream event (a JSON::Any).
#
# Divergences / DEFERRALS:
# - AWS Event Stream binary framing: ruby_llm decodes Bedrock's binary
#   `application/vnd.amazon.eventstream` frames with the `aws-eventstream` gem
#   (decode_chunk + Base64 inner payloads). The Crystal port has no in-tree
#   event-stream decoder yet, so the binary frame -> JSON::Any decoding is DEFERRED
#   (tracked with the Connection/streaming wiring). `build_chunk` below is the exact
#   event -> Chunk mapping and operates on the already-decoded event JSON, matching
#   the frozen `build_chunk(data : JSON::Any) : Chunk` signature. The base Streaming
#   mixin's SSE loop is OpenAI-shaped; a Bedrock-specific frame loop is future work.
# - Streaming error events (throttlingException etc.) -> raised errors: the
#   status-mapping is ported in `stream_error_status`; raising is left to the future
#   Bedrock stream loop (the base mixin doesn't surface it). `stream_error_event?` and
#   `stream_error_status` are ported for that wiring.
# - ToolCall ids/names are non-nil in CrystalLLM; ruby_llm's `nil`-keyed partial
#   tool-call deltas become `""`-keyed here (the accumulator merges by buffer
#   position — same convention as the OpenAI streaming port).
# - thinking text/signature are extracted but not attached to the Chunk (Message#thinking
#   deferred); reasoning_tokens ARE wired.
require "json"
require "../bedrock"

module CrystalLLM
  module Providers
    class Bedrock < Provider
      def stream_url : String
        "/model/#{@current_model.try(&.id)}/converse-stream"
      end

      def build_chunk(data : JSON::Any) : Chunk
        metadata_usage, usage, message_usage = event_usage(data)

        Chunk.new(
          role: Role::Assistant,
          model_id: stream_model_id(data),
          content: extract_content_delta(data),
          tool_calls: extract_tool_calls(data),
          input_tokens: extract_input_tokens(metadata_usage, usage, message_usage),
          output_tokens: extract_output_tokens(metadata_usage, usage),
          cached_tokens: extract_cached_tokens(metadata_usage, usage),
          cache_creation_tokens: extract_cache_creation_tokens(metadata_usage, usage),
          thinking_tokens: extract_reasoning_tokens(metadata_usage, usage)
        )
      end

      private def stream_model_id(event : JSON::Any) : String?
        event["modelId"]?.try(&.as_s?) ||
          event.dig?("message", "model").try(&.as_s?) ||
          @current_model.try(&.id)
      end

      # ---- Usage extraction ----

      private def event_usage(event : JSON::Any) : Tuple(Hash(String, JSON::Any), Hash(String, JSON::Any), Hash(String, JSON::Any))
        {
          event.dig?("metadata", "usage").try(&.as_h?) || {} of String => JSON::Any,
          event["usage"]?.try(&.as_h?) || {} of String => JSON::Any,
          event.dig?("message", "usage").try(&.as_h?) || {} of String => JSON::Any,
        }
      end

      private def extract_input_tokens(metadata_usage : Hash(String, JSON::Any),
                                       usage : Hash(String, JSON::Any),
                                       message_usage : Hash(String, JSON::Any)) : Int32?
        bedrock_usage = metadata_usage["inputTokens"]? ? metadata_usage : usage
        if bedrock_usage["inputTokens"]?
          return input_tokens(bedrock_usage)
        end

        int_at(message_usage["input_tokens"]?)
      end

      private def extract_output_tokens(metadata_usage : Hash(String, JSON::Any),
                                        usage : Hash(String, JSON::Any)) : Int32?
        int_at(metadata_usage["outputTokens"]?) ||
          int_at(usage["outputTokens"]?) ||
          int_at(usage["output_tokens"]?)
      end

      private def extract_cached_tokens(metadata_usage : Hash(String, JSON::Any),
                                        usage : Hash(String, JSON::Any)) : Int32?
        int_at(metadata_usage["cacheReadInputTokens"]?) ||
          int_at(usage["cacheReadInputTokens"]?) ||
          int_at(usage["cache_read_input_tokens"]?)
      end

      private def extract_cache_creation_tokens(metadata_usage : Hash(String, JSON::Any),
                                                usage : Hash(String, JSON::Any)) : Int32?
        int_at(metadata_usage["cacheWriteInputTokens"]?) ||
          int_at(usage["cacheWriteInputTokens"]?) ||
          int_at(usage["cache_creation_input_tokens"]?)
      end

      private def extract_reasoning_tokens(metadata_usage : Hash(String, JSON::Any),
                                           usage : Hash(String, JSON::Any)) : Int32?
        int_at(metadata_usage["reasoningTokens"]?) ||
          int_at(usage["reasoningTokens"]?) ||
          int_at(usage.dig?("output_tokens_details", "thinking_tokens"))
      end

      # ---- Error events (status mapping ported; raising deferred to the stream loop) ----

      def stream_error_event?(event : JSON::Any) : Bool
        hash = event.as_h?
        return false unless hash
        return true if hash.keys.any?(&.ends_with?("Exception"))
        event["type"]?.try(&.as_s?) == "error"
      end

      # {status, message} for a streaming error event (used by the future stream loop).
      def stream_error_status(event : JSON::Any) : Tuple(Int32, String)?
        hash = event.as_h?
        return nil unless hash

        if event["type"]?.try(&.as_s?) == "error"
          message = event.dig?("error", "message").try(&.as_s?) || "Bedrock streaming error"
          return {500, message}
        end

        key = hash.keys.find(&.ends_with?("Exception"))
        return nil unless key

        payload = hash[key].as_h? || {} of String => JSON::Any
        message = payload["message"]?.try(&.as_s?) || key
        status = case key
                 when "throttlingException"                                  then 429
                 when "validationException"                                  then 400
                 when "accessDeniedException", "unrecognizedClientException" then 401
                 when "serviceUnavailableException"                          then 503
                 else                                                             500
                 end
        {status, message}
      end

      # ---- Content / thinking deltas ----

      private def extract_content_delta(event : JSON::Any) : String?
        delta = normalized_delta(event)
        if text = delta["text"]?.try(&.as_s?)
          return text
        end

        if event.dig?("delta", "type").try(&.as_s?) == "text_delta"
          return event.dig?("delta", "text").try(&.as_s?)
        end

        nil
      end

      private def extract_thinking_delta(event : JSON::Any) : String?
        delta = normalized_delta(event)
        reasoning_text = delta.dig?("reasoningContent", "reasoningText").try(&.as_h?) || {} of String => JSON::Any
        if text = reasoning_text["text"]?.try(&.as_s?)
          return text
        end

        if event.dig?("delta", "type").try(&.as_s?) == "thinking_delta"
          return event.dig?("delta", "thinking").try(&.as_s?)
        end

        nil
      end

      # ---- Tool-call deltas ----

      private def extract_tool_calls(event : JSON::Any) : Hash(String, ToolCall)?
        return extract_tool_call_start(event) if tool_call_start_event?(event)
        return extract_tool_call_delta(event) if tool_call_delta_event?(event)

        nil
      end

      private def tool_call_start_event?(event : JSON::Any) : Bool
        !event["contentBlockStart"]?.nil? ||
          !event["start"]?.nil? ||
          !event.dig?("content_block", "tool_use").nil?
      end

      private def tool_call_delta_event?(event : JSON::Any) : Bool
        !event["contentBlockDelta"]?.nil? ||
          !event.dig?("delta", "toolUse").nil? ||
          !event.dig?("delta", "tool_use").nil? ||
          !event.dig?("delta", "partial_json").nil?
      end

      private def extract_tool_call_start(event : JSON::Any) : Hash(String, ToolCall)?
        tool_use = event.dig?("contentBlockStart", "start", "toolUse").try(&.as_h?)
        tool_use ||= event.dig?("start", "toolUse").try(&.as_h?)
        if tool_use.nil? && event["type"]?.try(&.as_s?) == "content_block_start"
          tool_use = event.dig?("content_block", "tool_use").try(&.as_h?)
        end
        return nil unless tool_use

        id = tool_use["toolUseId"]?.try(&.as_s?) || tool_use["id"]?.try(&.as_s?) || ""
        name = tool_use["name"]?.try(&.as_s?) || ""
        input = tool_use["input"]?.try(&.as_h?) || {} of String => JSON::Any

        {id => ToolCall.new(id: id, name: name, arguments: input)}
      end

      private def extract_tool_call_delta(event : JSON::Any) : Hash(String, ToolCall)?
        delta = normalized_delta(event)
        input = delta.dig?("toolUse", "input").try(&.as_h?)
        input ||= delta.dig?("tool_use", "input").try(&.as_h?)
        if input.nil? && event.dig?("delta", "type").try(&.as_s?) == "input_json_delta"
          input = event.dig?("delta", "partial_json").try(&.as_h?)
        end
        return nil unless input

        # ruby_llm keys this delta with `nil`; CrystalLLM ToolCall ids are non-nil, so
        # the partial keys with "" (the accumulator merges by buffer position).
        {"" => ToolCall.new(id: "", name: "", arguments: input)}
      end

      # The delta object, normalized to a Hash. ruby_llm: contentBlockDelta.delta ||
      # event.delta || {}, JSON-parsing a stringified delta.
      private def normalized_delta(event : JSON::Any) : JSON::Any
        delta = event.dig?("contentBlockDelta", "delta") || event["delta"]?
        return JSON::Any.new({} of String => JSON::Any) if delta.nil?

        return delta if delta.as_h?

        if str = delta.as_s?
          return JSON::Any.new({} of String => JSON::Any) if str.empty?
          begin
            return JSON.parse(str)
          rescue JSON::ParseException
            return JSON::Any.new({} of String => JSON::Any)
          end
        end

        JSON::Any.new({} of String => JSON::Any)
      end
    end
  end
end
