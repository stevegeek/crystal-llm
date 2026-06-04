# In-tree Server-Sent Events parser. Replaces ruby_llm's `event_stream_parser`
# dependency (lib/ruby_llm/streaming.rb fed chunks into it). Feed raw response
# chunks; yields (event_type, data) for each complete event (blank-line delimited),
# accumulating `data:` lines and tolerating chunk boundaries mid-line.
module CrystalLLM
  class SSE
    def initialize
      @buffer = ""
      @event_type = "message"
      @data = [] of String
    end

    # Feed a raw chunk; yields (type, data) per complete event found so far.
    def feed(chunk : String, & : String, String ->) : Nil
      @buffer += chunk
      while nl = @buffer.index('\n')
        line = @buffer[0, nl].rstrip('\r')
        @buffer = @buffer[(nl + 1)..]
        dispatch_line(line) { |type, data| yield type, data }
      end
    end

    private def dispatch_line(line : String, & : String, String ->) : Nil
      if line.empty?
        emit { |type, data| yield type, data }
        return
      end
      return if line.starts_with?(':') # comment line

      field, _, value = line.partition(':')
      value = value[1..] if value.starts_with?(' ') # strip one optional leading space

      case field
      when "event" then @event_type = value
      when "data"  then @data << value
      else
        # id / retry / unknown fields: tracked by the SSE spec but unused here
      end
    end

    private def emit(& : String, String ->) : Nil
      yield @event_type, @data.join('\n') unless @data.empty?
      @event_type = "message"
      @data = [] of String
    end
  end
end
