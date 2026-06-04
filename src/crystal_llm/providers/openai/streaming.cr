# ported from lib/ruby_llm/providers/openai/streaming.rb @ ruby_llm 1.15.0
#
# Builds a Chunk from one OpenAI SSE `data:` event. The Streaming mixin (streaming.cr)
# drives the SSE loop and calls `build_chunk` per parsed event; this is the OpenAI
# delta -> Chunk mapping.
#
# Divergences:
# - tool-call deltas are parsed with `parse_arguments: false` so the streaming
#   accumulator merges them (see tools.cr's note on the typed-arguments divergence).
# - thinking text/signature are extracted but not attached to the Chunk (Message#thinking
#   deferred); reasoning_tokens ARE wired. `parse_streaming_error` is ported for the
#   streaming-error-status mapping (used once the stream loop surfaces errors).
require "json"
require "../openai"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      def stream_url : String
        completion_url
      end

      def build_chunk(data : JSON::Any) : Chunk
        usage = data["usage"]?.try(&.as_h?) || {} of String => JSON::Any
        delta = data.dig?("choices", 0, "delta").try(&.as_h?) || {} of String => JSON::Any

        content_source = delta["content"]? || data.dig?("choices", 0, "message", "content")
        content, _thinking_from_blocks = extract_content_and_thinking(content_source)

        Chunk.new(
          role: Role::Assistant,
          model_id: data["model"]?.try(&.as_s?),
          content: content,
          tool_calls: parse_tool_calls(delta["tool_calls"]?, parse_arguments: false),
          input_tokens: input_tokens(usage),
          output_tokens: output_tokens(usage),
          cached_tokens: cache_read_tokens(usage),
          cache_creation_tokens: cache_write_tokens(usage),
          thinking_tokens: thinking_tokens(usage)
        )
      end

      # Maps a streaming error event to {status, message} (used by the stream loop
      # to raise the right error type). Returns nil for a non-error event.
      def parse_streaming_error(data : String) : Tuple(Int32, String)?
        error_data = JSON.parse(data)
        error = error_data["error"]?.try(&.as_h?)
        return nil unless error

        message = error["message"]?.try(&.as_s?) || ""
        case error["type"]?.try(&.as_s?)
        when "server_error"
          {500, message}
        when "rate_limit_exceeded", "insufficient_quota"
          {429, message}
        else
          {400, message}
        end
      rescue JSON::ParseException
        nil
      end
    end
  end
end
