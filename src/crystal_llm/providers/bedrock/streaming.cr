# ported from lib/ruby_llm/providers/bedrock/streaming.rb @ ruby_llm 1.15.0
#
# Decodes Bedrock ConverseStream's binary `application/vnd.amazon.eventstream`
# frames into JSON::Any events and builds a Chunk per event.
#
# Divergences / DEFERRALS:
# - AWS Event Stream binary framing: ruby_llm decodes Bedrock's binary frames with
#   the `aws-eventstream` gem (Decoder#decode_chunk + Base64 inner payloads). The
#   Crystal port hand-rolls the frame format in `decode_event_stream` /
#   `decode_event_frame` (4-byte total len, 4-byte headers len, 4-byte prelude CRC,
#   headers, payload, 4-byte message CRC — all big-endian) using
#   IO::ByteFormat::BigEndian + Digest::CRC32, then peels the outer
#   `{"bytes": base64}` wrapper in `decode_event_payload`. `stream_response` is
#   overridden to drive that decoder instead of the base SSE mixin (which is
#   OpenAI/SSE-shaped and cannot parse binary frames).
# - Streaming error events (throttlingException etc.) -> raised errors: the
#   status-mapping is ported in `stream_error_status` and now raised from
#   `stream_response` via ErrorMiddleware (`stream_error_event?` gates it).
# - ToolCall ids/names are non-nil in CrystalLLM; ruby_llm's `nil`-keyed partial
#   tool-call deltas become `""`-keyed here (the accumulator merges by buffer
#   position — same convention as the OpenAI streaming port). The toolUse input
#   partial-JSON fragment rides on ToolCall#raw_arguments (parsed once at the end).
# - thinking text/signature are extracted but not attached to the Chunk (Message#thinking
#   deferred); reasoning_tokens ARE wired.
require "json"
require "base64"
require "digest/crc32"
require "../bedrock"

module CrystalLLM
  module Providers
    class Bedrock < Provider
      # Raised when an eventstream frame fails its CRC32 integrity check or is
      # otherwise malformed (truncated prelude/length fields).
      class EventStreamError < CrystalLLM::Error
      end

      # Size of the message prelude: total-length (4) + headers-length (4) +
      # prelude-CRC (4). Plus the trailing 4-byte message CRC = 16 framing bytes.
      PRELUDE_BYTES = 12
      FRAMING_BYTES = 16

      def stream_url : String
        "/model/#{@current_model.try(&.id)}/converse-stream"
      end

      # Bedrock streaming override: the response body is a sequence of binary
      # `application/vnd.amazon.eventstream` frames (not SSE), so the base
      # `Streaming#stream_response` SSE loop cannot be used. Reads frames off
      # `body_io`, decodes each inner JSON event, raises mapped errors for
      # exception/error events, and feeds the rest to `build_chunk`.
      def stream_response(payload : String, headers : Hash(String, String) = {} of String => String,
                          &block : Chunk ->) : Message
        accumulator = StreamAccumulator.new
        url = stream_url
        signed = sign_headers("POST", url, payload).merge(headers)
        # Bedrock requires this Accept to receive eventstream framing.
        signed = signed.merge({"Accept" => "application/vnd.amazon.eventstream"})

        connection.post_stream(url, payload, signed) do |response|
          decode_event_stream(response.body_io) do |event|
            if stream_error_event?(event)
              if mapped = stream_error_status(event)
                status, message = mapped
                ErrorMiddleware.parse_error(status, message, nil)
              end
            end

            chunk = build_chunk(event)
            accumulator.add(chunk)
            block.call(chunk)
          end
        end

        accumulator.to_message(nil)
      end

      # Reads AWS event-stream frames off *io* and yields each decoded model event
      # (a JSON::Any). Frames whose payload carries no decodable JSON are skipped
      # (ruby_llm: decode_event_payload returns nil and is dropped).
      def decode_event_stream(io : IO, & : JSON::Any ->) : Nil
        while payload = read_event_frame(io)
          event = decode_event_payload(payload)
          yield event if event
        end
      end

      # Reads ONE full frame off *io* and returns its raw payload bytes, or nil at
      # clean EOF. Validates the prelude + message CRC32s (ruby_llm relies on the
      # aws-eventstream gem to do this; we do it inline).
      private def read_event_frame(io : IO) : Bytes?
        prelude = Bytes.new(PRELUDE_BYTES)
        read = read_fully(io, prelude)
        return nil if read.zero? # clean EOF between frames
        raise EventStreamError.new("Truncated eventstream prelude") if read < PRELUDE_BYTES

        total_len = IO::ByteFormat::BigEndian.decode(UInt32, prelude[0, 4])
        headers_len = IO::ByteFormat::BigEndian.decode(UInt32, prelude[4, 4])
        prelude_crc = IO::ByteFormat::BigEndian.decode(UInt32, prelude[8, 4])

        if Digest::CRC32.checksum(prelude[0, 8]) != prelude_crc
          raise EventStreamError.new("Eventstream prelude CRC mismatch")
        end

        if total_len < FRAMING_BYTES + headers_len
          raise EventStreamError.new("Eventstream frame length out of range")
        end

        # Remainder = everything after the prelude: headers + payload + message CRC.
        remainder = Bytes.new(total_len - PRELUDE_BYTES)
        raise EventStreamError.new("Truncated eventstream frame") if read_fully(io, remainder) < remainder.size

        message_crc = IO::ByteFormat::BigEndian.decode(UInt32, remainder[remainder.size - 4, 4])
        # Message CRC covers the whole frame except the trailing CRC itself.
        crc = Digest::CRC32.update(prelude, 0_u32)
        crc = Digest::CRC32.update(remainder[0, remainder.size - 4], crc)
        raise EventStreamError.new("Eventstream message CRC mismatch") if crc != message_crc

        payload_len = remainder.size - headers_len - 4
        # Headers themselves are not needed to extract the model event JSON.
        remainder[headers_len, payload_len]
      end

      # Reads up to buf.size bytes, returning the count actually read. Wraps
      # IO#read_fully?'s partial-read handling so callers can distinguish clean EOF
      # (0) from a truncated frame (< buf.size).
      private def read_fully(io : IO, buf : Bytes) : Int32
        total = 0
        while total < buf.size
          n = io.read(buf[total, buf.size - total])
          break if n.zero?
          total += n
        end
        total
      end

      # Decodes one frame payload (raw JSON bytes) into the model event JSON.
      # ruby_llm: parse the outer JSON; if it carries a base64 `"bytes"` string,
      # base64-decode + re-parse that (the actual model SSE-style event); otherwise
      # the outer JSON *is* the event. Returns nil on unparseable payloads (dropped).
      def decode_event_payload(payload : Bytes) : JSON::Any?
        outer = JSON.parse(String.new(payload))
        if bytes = outer["bytes"]?.try(&.as_s?)
          JSON.parse(String.new(Base64.decode(bytes)))
        else
          outer
        end
      rescue JSON::ParseException | Base64::Error
        nil
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

        # Bedrock's ConverseStream toolUse `input` arrives as a raw partial-JSON
        # String fragment (NOT a parsed object), same as Anthropic's partial_json.
        raw = delta.dig?("toolUse", "input").try(&.as_s?)
        raw ||= delta.dig?("tool_use", "input").try(&.as_s?)
        if raw.nil? && event.dig?("delta", "type").try(&.as_s?) == "input_json_delta"
          raw = event.dig?("delta", "partial_json").try(&.as_s?)
        end
        return nil if raw.nil?

        # ruby_llm keys this delta with `nil`; CrystalLLM ToolCall ids are non-nil, so
        # the partial keys with "". The raw fragment rides on raw_arguments and the
        # accumulator concatenates + parses the stream once (by buffer position).
        {"" => ToolCall.new(id: "", name: "", raw_arguments: raw)}
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
