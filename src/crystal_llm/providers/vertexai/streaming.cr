# ported from lib/ruby_llm/providers/vertexai/streaming.rb + lib/ruby_llm/providers/gemini/streaming.rb @ ruby_llm 1.16.0
#
# stream_url is the VertexAI override; build_chunk is the Gemini delta -> Chunk mapping.
#
# Divergences:
# - thinking text/signature are NOT attached to the Chunk (Message#thinking deferred);
#   thinking_tokens ARE wired.
# - output_tokens returns nil when the running total is 0 (mirrors gemini/streaming.rb's
#   `total.positive? ? total : nil`, which differs from the sync path's `candidates+thoughts`).
require "json"
require "../vertexai"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      def stream_url : String
        "projects/#{@config.vertexai_project_id}/locations/#{@config.vertexai_location}/" \
        "publishers/google/models/#{@last_model}:streamGenerateContent?alt=sse"
      end

      def build_chunk(data : JSON::Any) : Chunk
        parts = data.dig?("candidates", 0, "content", "parts").try(&.as_a?) || [] of JSON::Any
        usage = data["usageMetadata"]?.try(&.as_h?) || {} of String => JSON::Any

        Chunk.new(
          role: Role::Assistant,
          model_id: data["modelVersion"]?.try(&.as_s?),
          content: extract_text_parts(parts),
          tool_calls: extract_tool_calls(data),
          input_tokens: input_tokens(usage),
          output_tokens: extract_output_tokens(usage),
          cached_tokens: int_at(usage["cachedContentTokenCount"]?),
          thinking_tokens: int_at(usage["thoughtsTokenCount"]?)
        )
      end

      # candidates + thoughts, but nil when the total is 0 (streaming variant).
      private def extract_output_tokens(usage : Hash(String, JSON::Any)) : Int32?
        candidates = int_at(usage["candidatesTokenCount"]?) || 0
        thoughts = int_at(usage["thoughtsTokenCount"]?) || 0
        total = candidates + thoughts
        total > 0 ? total : nil
      end

      # Maps a streaming error event to {status, message}. nil for a non-error event.
      def parse_streaming_error(data : String) : Tuple(Int32, String)?
        error_data = JSON.parse(data)
        error = error_data["error"]?.try(&.as_h?)
        return nil unless error
        code = int_at(error["code"]?) || 500
        message = error["message"]?.try(&.as_s?) || "Failed to parse error: #{data}"
        {code, message}
      rescue JSON::ParseException
        {500, "Failed to parse error: #{data}"}
      end
    end
  end
end
