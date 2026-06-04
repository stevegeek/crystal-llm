# ported from lib/ruby_llm/streaming.rb @ ruby_llm 1.15.0
#
# ruby_llm's streaming is Faraday-specific (on_data handlers, env, version checks).
# The Crystal port streams crest's body_io, parses SSE in-tree (see sse.cr), and
# delegates per-event parsing to the provider's `build_chunk`. Mixed into Provider.
require "json"
require "./sse"
require "./stream_accumulator"

module CrystalLLM
  module Streaming
    # Streams a completion: POSTs, reads the SSE body line by line, builds a Chunk
    # per data event (via the provider's `build_chunk`), accumulates + yields each
    # chunk to the block, and returns the final assembled Message.
    def stream_response(payload : String, headers : Hash(String, String) = {} of String => String,
                        &block : Chunk ->) : Message
      accumulator = StreamAccumulator.new
      parser = SSE.new

      connection.post_stream(stream_url, payload, headers) do |response|
        response.body_io.each_line do |line|
          parser.feed("#{line}\n") do |_type, data|
            next if data == "[DONE]"
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

    private def parse_chunk_json(data : String) : JSON::Any?
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end
  end
end
