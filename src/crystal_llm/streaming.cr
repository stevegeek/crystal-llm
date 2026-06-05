# ported from lib/ruby_llm/streaming.rb @ ruby_llm 1.15.0
#
# ruby_llm's streaming is Faraday-specific (on_data handlers, env, version checks).
# The Crystal port streams crest's body_io, parses SSE in-tree (see sse.cr), and
# delegates per-event parsing to the provider's `build_chunk`. Mixed into Provider.
require "json"
require "./sse"
require "./stream_accumulator"
require "./error_middleware"

module CrystalLLM
  module Streaming
    # Streams a completion: POSTs, reads the SSE body line by line, builds a Chunk
    # per data event (via the provider's `build_chunk`), accumulates + yields each
    # chunk to the block, and returns the final assembled Message.
    def stream_response(payload : String, headers : Hash(String, String) = {} of String => String,
                        &block : Chunk ->) : Message
      accumulator = StreamAccumulator.new
      parser = SSE.new

      url = stream_url
      # Per-request signing hook (default no-op; Bedrock computes SigV4). Caller
      # `headers` win on conflict, matching the sync path's merge order.
      signed = sign_headers("POST", url, payload).merge(headers)
      connection.post_stream(url, payload, signed) do |response|
        response.body_io.each_line do |line|
          parser.feed("#{line}\n") do |type, data|
            next if data == "[DONE]"

            # Surface streaming error events / error payloads as raised CrystalLLM
            # errors (ruby_llm: handle_error_event / handle_data's error branch).
            # An SSE `event: error`, or a data payload whose parsed Hash carries an
            # `"error"` key, is mapped via the provider's parse_streaming_error and
            # raised through ErrorMiddleware — instead of being fed to build_chunk.
            raise_if_stream_error(type, data)

            json = parse_chunk_json(data)
            next unless json

            chunk = build_chunk(json)
            accumulator.add(chunk)
            block.call(chunk)
          end
        end
      end

      accumulator.to_message(nil)
    end

    # Raises a mapped CrystalLLM error when *data* represents a streaming error,
    # either via an SSE `event: error` or an `"error"` key in the parsed payload.
    # No-op for normal chunks.
    private def raise_if_stream_error(type : String, data : String) : Nil
      return unless type == "error" || error_payload?(data)

      mapped = parse_streaming_error(data)
      return unless mapped

      status, message = mapped
      ErrorMiddleware.parse_error(status, message, nil)
    end

    private def error_payload?(data : String) : Bool
      json = parse_chunk_json(data)
      return false unless json
      (hash = json.as_h?) ? hash.has_key?("error") : false
    end

    private def parse_chunk_json(data : String) : JSON::Any?
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end
  end
end
