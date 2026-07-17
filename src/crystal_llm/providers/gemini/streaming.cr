# ported from lib/ruby_llm/providers/gemini/streaming.rb @ ruby_llm 1.16.0
#
# Builds a Chunk from one Gemini SSE event (streamGenerateContent?alt=sse). The
# Streaming mixin (streaming.cr) drives the SSE loop and calls `build_chunk` per
# parsed event; this is the Gemini candidate-delta -> Chunk mapping.
#
# Divergences:
# - thinking text (thought parts) + signature (thoughtSignature) ARE attached to the
#   Chunk via `Thinking.build`; the StreamAccumulator folds them into the final
#   Message. thinking_tokens ARE wired.
# - `parse_streaming_error` is ported for the streaming-error-status mapping (used
#   once the stream loop surfaces errors).
require "json"
require "../gemini"

module CrystalLLM
  module Providers
    class Gemini < Provider
      def stream_url : String
        "models/#{require_model_id}:streamGenerateContent?alt=sse"
      end

      def build_chunk(data : JSON::Any) : Chunk
        parts = data.dig?("candidates", 0, "content", "parts").try(&.as_a?) || [] of JSON::Any

        Chunk.new(
          role: Role::Assistant,
          model_id: data["modelVersion"]?.try(&.as_s?),
          content: extract_text_parts(parts),
          thinking: Thinking.build(
            text: extract_thought_parts(parts),
            signature: extract_thought_signature(parts)
          ),
          input_tokens: input_tokens(data),
          output_tokens: extract_output_tokens(data),
          cached_tokens: usage_int(data, "cachedContentTokenCount"),
          thinking_tokens: usage_int(data, "thoughtsTokenCount"),
          tool_calls: extract_tool_calls(data)
        )
      end

      # Like calculate_output_tokens but returns nil when the total is zero (so an
      # intermediate streaming delta with no usage doesn't report 0 tokens).
      def extract_output_tokens(data : JSON::Any) : Int32?
        candidates = usage_int(data, "candidatesTokenCount") || 0
        thoughts = usage_int(data, "thoughtsTokenCount") || 0
        total = candidates + thoughts
        total > 0 ? total : nil
      end

      # Maps a Gemini streaming error event to {status, message}. Returns nil for a
      # non-error / unparseable event (mirrors ruby_llm's rescue -> [500, ...], but
      # the Crystal stream loop treats nil as "not an error").
      def parse_streaming_error(data : String) : Tuple(Int32, String)?
        error_data = JSON.parse(data)
        error = error_data["error"]?.try(&.as_h?)
        return nil unless error

        code = error["code"]?.try(&.as_i?) || 500
        message = error["message"]?.try(&.as_s?) || ""
        {code, message}
      rescue JSON::ParseException
        {500, "Failed to parse error: #{data}"}
      end
    end
  end
end
