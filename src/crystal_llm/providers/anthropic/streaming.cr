# ported from lib/ruby_llm/providers/anthropic/streaming.rb @ ruby_llm 1.16.0
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
#   ToolCall#raw_arguments; a non-delta `content_block` is parsed via Tools.parse_tool_calls.
# - Parallel tool-call streaming (ruby_llm 1.16.0 / ff19c933): Anthropic streams
#   parallel tool calls as interleaved content_block_start/content_block_delta
#   events distinguished only by an integer content-block `index`. `extract_tool_calls`
#   keys both the tool-call start and its delta fragments by `data["index"].to_s`
#   (stringified so the returned Hash stays single-keyed — see
#   StreamAccumulator#@tool_call_ids_by_index) instead of a constant `""` key, so
#   the StreamAccumulator routes interleaved fragments to the right call. FILE
#   LOCATION DIVERGENCE: upstream's fix lives in `providers/anthropic/tools.rb`
#   (its `extract_tool_calls` lives there); this port already located
#   `extract_tool_calls` here in streaming.cr (a pre-existing organizational
#   choice, documented in the original port), so the parity fix is applied here
#   instead of in tools.cr.
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
          model_id: extract_model_id(data),
          content: extract_content_delta(data, delta_type),
          thinking: Thinking.build(
            text: extract_thinking_delta(data, delta_type),
            signature: extract_signature_delta(data, delta_type)
          ),
          input_tokens: extract_input_tokens(data),
          output_tokens: extract_output_tokens(data),
          cached_tokens: extract_cached_tokens(data),
          cache_creation_tokens: extract_cache_creation_tokens(data),
          tool_calls: extract_tool_calls(data)
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

      private def extract_model_id(data : JSON::Any) : String?
        data.dig?("message", "model").try(&.as_s?)
      end

      private def extract_input_tokens(data : JSON::Any) : Int32?
        int_at(data.dig?("message", "usage", "input_tokens"))
      end

      private def extract_output_tokens(data : JSON::Any) : Int32?
        int_at(data.dig?("message", "usage", "output_tokens")) ||
          int_at(data.dig?("usage", "output_tokens"))
      end

      private def extract_cached_tokens(data : JSON::Any) : Int32?
        int_at(data.dig?("message", "usage", "cache_read_input_tokens")) ||
          int_at(data.dig?("usage", "cache_read_input_tokens"))
      end

      private def extract_cache_creation_tokens(data : JSON::Any) : Int32?
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

      private def content_block_start?(data : JSON::Any) : Bool
        data["type"]?.try(&.as_s?) == "content_block_start"
      end

      private def extract_tool_calls(data : JSON::Any) : Hash(String, ToolCall)?
        if json_delta?(data)
          extract_tool_call_delta(data)
        elsif content_block_start?(data)
          extract_tool_call_start(data)
        else
          Tools.parse_tool_calls(data["content_block"]?)
        end
      end

      # Carries the raw partial_json fragment String through to the accumulator,
      # which concatenates all fragments and parses the result once. Parsing
      # each fragment in isolation here would yield {} (they are partials). Keyed
      # by the stringified content-block `index` (CrystalLLM's tool-call hash key
      # type is String; Anthropic's stream key is an integer index, represented
      # here as its string form so `Hash(String, ToolCall)` stays single-keyed) so
      # interleaved deltas for parallel tool calls land on the right call instead
      # of clobbering via a constant `""` key.
      private def extract_tool_call_delta(data : JSON::Any) : Hash(String, ToolCall)?
        fragment = data.dig?("delta", "partial_json").try(&.as_s?) || ""
        index = data["index"]?.try(&.as_i?)
        stream_key = index ? index.to_s : ""
        {stream_key => ToolCall.new(id: "", name: "", raw_arguments: fragment)}
      end

      # Parses the started tool_use content block, then rekeys the single
      # resulting tool call under its stringified content-block `index` (rather
      # than its id) so the StreamAccumulator can associate later index-keyed
      # deltas with it via `@tool_call_ids_by_index`.
      private def extract_tool_call_start(data : JSON::Any) : Hash(String, ToolCall)?
        tool_calls = Tools.parse_tool_calls(data["content_block"]?)
        return tool_calls if tool_calls.nil?

        index = data["index"]?.try(&.as_i?)
        return tool_calls if index.nil?

        {index.to_s => tool_calls.values.first}
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
