# ported from lib/ruby_llm/providers/anthropic/streaming.rb @ ruby_llm 1.15.0
#
# Builds a Chunk from one Anthropic SSE event. The Streaming mixin (streaming.cr)
# drives the SSE loop and calls `build_chunk` per parsed event; this is the Anthropic
# event -> Chunk mapping.
#
# Anthropic streaming events differ from OpenAI's: the model id + usage live under a
# `message` key (on `message_start`) or top-level `usage` (on `message_delta`); text/
# thinking/signature arrive as typed `delta` events (`text_delta`/`thinking_delta`/
# `signature_delta`); tool-call argument fragments arrive as `input_json_delta`.
#
# Divergences:
# - thinking text (thinking_delta) and signature (signature_delta) ARE attached to the
#   Chunk via `Thinking.build`; the StreamAccumulator folds them into the final Message.
#   thinking_tokens are not separately carried on chunk usage (Anthropic does not split
#   them on stream events). `parse_streaming_error` is ported for the streaming
#   error-status mapping (overloaded_error -> 529, else 500).
# - tool-call deltas: an `input_json_delta` carries a `partial_json` fragment. ToolCall#
#   arguments is a typed Hash (can't hold a partial), so the raw fragment String rides on
#   ToolCall#raw_arguments keyed by "" and the StreamAccumulator concatenates + parses the
#   fragments once; a non-delta `content_block` is parsed via Tools.parse_tool_calls.
require "json"
require "../anthropic"

module CrystalLLM
  module Providers
    class Anthropic < Provider
      def stream_url : String
        completion_url
      end

      def build_chunk(data : JSON::Any) : Chunk
        delta_type = data.dig?("delta", "type").try(&.as_s?)

        Chunk.new(
          role: Role::Assistant,
          model_id: extract_stream_model_id(data),
          content: extract_content_delta(data, delta_type),
          thinking: Thinking.build(
            text: extract_thinking_delta(data, delta_type),
            signature: extract_signature_delta(data, delta_type)
          ),
          input_tokens: extract_stream_input_tokens(data),
          output_tokens: extract_stream_output_tokens(data),
          cached_tokens: extract_stream_cached_tokens(data),
          cache_creation_tokens: extract_stream_cache_creation_tokens(data),
          tool_calls: extract_stream_tool_calls(data)
        )
      end

      private def extract_content_delta(data : JSON::Any, delta_type : String?) : String?
        return data.dig?("delta", "text").try(&.as_s?) if delta_type == "text_delta"
        nil
      end

      private def extract_thinking_delta(data : JSON::Any, delta_type : String?) : String?
        return data.dig?("delta", "thinking").try(&.as_s?) if delta_type == "thinking_delta"
        nil
      end

      private def extract_signature_delta(data : JSON::Any, delta_type : String?) : String?
        return data.dig?("delta", "signature").try(&.as_s?) if delta_type == "signature_delta"
        nil
      end

      private def extract_stream_model_id(data : JSON::Any) : String?
        data.dig?("message", "model").try(&.as_s?)
      end

      private def extract_stream_input_tokens(data : JSON::Any) : Int32?
        int_at(data.dig?("message", "usage", "input_tokens"))
      end

      private def extract_stream_output_tokens(data : JSON::Any) : Int32?
        int_at(data.dig?("message", "usage", "output_tokens")) ||
          int_at(data.dig?("usage", "output_tokens"))
      end

      private def extract_stream_cached_tokens(data : JSON::Any) : Int32?
        int_at(data.dig?("message", "usage", "cache_read_input_tokens")) ||
          int_at(data.dig?("usage", "cache_read_input_tokens"))
      end

      private def extract_stream_cache_creation_tokens(data : JSON::Any) : Int32?
        direct = int_at(data.dig?("message", "usage", "cache_creation_input_tokens")) ||
                 int_at(data.dig?("usage", "cache_creation_input_tokens"))
        return direct if direct

        breakdown = data.dig?("message", "usage", "cache_creation").try(&.as_h?) ||
                    data.dig?("usage", "cache_creation").try(&.as_h?)
        return nil unless breakdown
        sum_values(breakdown)
      end

      private def json_delta?(data : JSON::Any) : Bool
        data["type"]?.try(&.as_s?) == "content_block_delta" &&
          data.dig?("delta", "type").try(&.as_s?) == "input_json_delta"
      end

      private def extract_stream_tool_calls(data : JSON::Any) : Hash(String, ToolCall)?
        if json_delta?(data)
          # Carry the raw partial_json fragment String through to the accumulator,
          # which concatenates all fragments and parses the result once. Parsing
          # each fragment in isolation here would yield {} (they are partials).
          fragment = data.dig?("delta", "partial_json").try(&.as_s?) || ""
          {"" => ToolCall.new(id: "", name: "", raw_arguments: fragment)}
        else
          Tools.parse_tool_calls(data["content_block"]?)
        end
      end

      # Maps a streaming error event to {status, message}. Returns nil for a non-error.
      def parse_streaming_error(data : String) : Tuple(Int32, String)?
        error_data = JSON.parse(data)
        return nil unless error_data["type"]?.try(&.as_s?) == "error"

        error = error_data["error"]?.try(&.as_h?) || {} of String => JSON::Any
        message = error["message"]?.try(&.as_s?) || ""
        case error["type"]?.try(&.as_s?)
        when "overloaded_error"
          {529, message}
        else
          {500, message}
        end
      rescue JSON::ParseException
        nil
      end
    end
  end
end
