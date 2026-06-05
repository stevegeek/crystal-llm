# ported from lib/ruby_llm/stream_accumulator.rb @ ruby_llm 1.15.0
require "json"
require "uuid"
require "./chunk"
require "./message"
require "./tool_call"
require "./tokens"
require "./thinking"

module CrystalLLM
  # Assembles streaming responses from LLMs into complete messages.
  #
  # DIVERGENCE (typed tool-call arguments): ruby_llm keeps each tool call's
  # `arguments` as a mutable String buffer while streaming, appending raw JSON
  # fragments, then `JSON.parse`s the buffer in `to_message`. CrystalLLM's
  # `ToolCall#arguments` is a typed `Hash(String, JSON::Any)` (design's JSONData
  # shape), so a partial-JSON String cannot live there. Streaming providers carry
  # the raw fragment on `ToolCall#raw_arguments` (a String channel); we accumulate
  # into private per-id buffers (`ToolCallBuffer`) and only materialize `ToolCall`
  # values in `to_message`. A buffer concatenates the raw fragment stream and
  # `JSON.parse`s it ONCE at the end (matching ruby_llm), or merges pre-parsed Hash
  # arguments — covering both the fragment-delta wire shape and providers that hand
  # us already-parsed Hashes.
  #
  # Structured thinking: `append_thinking_from_chunk` reads `chunk.thinking` (the
  # text/signature a provider attaches per streaming delta) and folds it into the
  # accumulated thinking; `to_message` attaches the result to the final Message.
  # The `<think>`-tag extraction over content text is a separate, parallel path
  # (used by providers that inline reasoning in the content stream).
  class StreamAccumulator
    getter content : String
    getter model_id : String?

    @thinking_signature : String?
    @input_tokens : Int32?
    @output_tokens : Int32?
    @cached_tokens : Int32?
    @cache_creation_tokens : Int32?
    @thinking_tokens : Int32?
    @latest_tool_call_id : String?

    def initialize
      @content = ""
      @thinking_text = ""
      @thinking_signature = nil
      @input_tokens = nil
      @output_tokens = nil
      @cached_tokens = nil
      @cache_creation_tokens = nil
      @thinking_tokens = nil
      @inside_think_tag = false
      @pending_think_tag = ""
      @latest_tool_call_id = nil
      @model_id = nil
      @tool_calls = {} of String => ToolCallBuffer
    end

    def add(chunk : Chunk) : Nil
      @model_id ||= chunk.model_id

      handle_chunk_content(chunk)
      append_thinking_from_chunk(chunk)
      count_tokens(chunk)
    end

    # Accumulated thinking. Exposed so the data survives even though `to_message`
    # cannot yet attach it to the Message (deferral above).
    def thinking : Thinking?
      Thinking.build(
        text: @thinking_text.empty? ? nil : @thinking_text,
        signature: @thinking_signature
      )
    end

    def to_message(response : JSON::Any?) : Message
      Message.new(
        role: Role::Assistant,
        content: @content.empty? ? nil : @content,
        thinking: thinking,
        tokens: Tokens.build(
          input: @input_tokens,
          output: @output_tokens,
          cached: @cached_tokens,
          cache_creation: @cache_creation_tokens,
          thinking: @thinking_tokens
        ),
        model_id: @model_id,
        tool_calls: tool_calls_from_stream,
        raw: response
      )
    end

    private def tool_calls_from_stream : Hash(String, ToolCall)?
      return nil if @tool_calls.empty?

      result = {} of String => ToolCall
      @tool_calls.each do |key, buffer|
        result[key] = buffer.to_tool_call
      end
      result
    end

    private def accumulate_tool_calls(new_tool_calls : Hash(String, ToolCall)) : Nil
      new_tool_calls.each_value do |tool_call|
        # ruby_llm branches on `tool_call.id` being present vs nil. Crystal's
        # ToolCall#id is a non-nilable String, so an empty id marks a continuation
        # delta (the wire equivalent of ruby_llm's nil id).
        if !tool_call.id.empty?
          tool_call_id = tool_call.id
          buffer = ToolCallBuffer.new(
            id: tool_call_id,
            name: tool_call.name,
            thought_signature: tool_call.thought_signature
          )
          ingest_arguments(buffer, tool_call)
          @tool_calls[tool_call.id] = buffer
          @latest_tool_call_id = tool_call.id
        elsif (latest = @latest_tool_call_id) && (existing = @tool_calls[latest]?)
          ingest_arguments(existing, tool_call)
          if (sig = tool_call.thought_signature) && existing.thought_signature.nil?
            existing.thought_signature = sig
          end
        end
      end
    end

    # Routes a delta's arguments into the buffer: a raw partial-JSON String
    # fragment (the streaming wire shape — buffered + parsed once at the end) takes
    # precedence; otherwise an already-parsed Hash is merged (providers that hand us
    # parsed args, e.g. a non-delta content_block).
    private def ingest_arguments(buffer : ToolCallBuffer, tool_call : ToolCall) : Nil
      raw = tool_call.raw_arguments
      if raw
        buffer.append_fragment(raw)
      else
        buffer.merge_arguments(tool_call.arguments)
      end
    end

    private def count_tokens(chunk : Chunk) : Nil
      @input_tokens = chunk.input_tokens if chunk.input_tokens
      @output_tokens = chunk.output_tokens if chunk.output_tokens
      @cached_tokens = chunk.cached_tokens if chunk.cached_tokens
      @cache_creation_tokens = chunk.cache_creation_tokens if chunk.cache_creation_tokens
      @thinking_tokens = chunk.thinking_tokens if chunk.thinking_tokens
    end

    private def handle_chunk_content(chunk : Chunk) : Nil
      return accumulate_tool_calls(chunk.tool_calls || {} of String => ToolCall) if chunk.tool_call?

      content_text = chunk.content
      case content_text
      when String
        append_text_with_thinking(content_text)
      when Nil
        append_text_with_thinking("")
      else
        @content += content_text.to_s
      end
    end

    private def append_text_with_thinking(text : String) : Nil
      content_chunk, thinking_chunk = extract_think_tags(text)
      @content += content_chunk
      @thinking_text += thinking_chunk if thinking_chunk
    end

    # Folds a chunk's structured thinking (Chunk#thinking, set by providers that
    # stream reasoning as typed deltas — Anthropic thinking_delta/signature_delta,
    # Gemini thoughts, OpenRouter/OpenAI reasoning) into the accumulated thinking.
    # Mirrors ruby_llm: append text, keep the FIRST non-nil signature.
    private def append_thinking_from_chunk(chunk : Chunk) : Nil
      thinking = chunk.thinking
      return unless thinking
      if text = thinking.text
        @thinking_text += text
      end
      @thinking_signature ||= thinking.signature
    end

    private def extract_think_tags(text : String) : Tuple(String, String?)
      start_tag = "<think>"
      end_tag = "</think>"
      remaining = @pending_think_tag + text
      @pending_think_tag = ""

      output = ""
      thinking = ""

      until remaining.empty?
        if @inside_think_tag
          remaining, thinking = consume_think_content(remaining, end_tag, thinking)
        else
          remaining, output = consume_non_think_content(remaining, start_tag, output)
        end
      end

      {output, thinking.empty? ? nil : thinking}
    end

    private def consume_think_content(remaining : String, end_tag : String,
                                      thinking : String) : Tuple(String, String)
      if end_index = remaining.index(end_tag)
        thinking += remaining[0, end_index]
        @inside_think_tag = false
        {remaining[(end_index + end_tag.size)..]? || "", thinking}
      else
        suffix_len = longest_suffix_prefix(remaining, end_tag)
        thinking += remaining[0, remaining.size - suffix_len]
        @pending_think_tag = suffix_len.zero? ? "" : remaining[(remaining.size - suffix_len), suffix_len]
        {"", thinking}
      end
    end

    private def consume_non_think_content(remaining : String, start_tag : String,
                                          output : String) : Tuple(String, String)
      if start_index = remaining.index(start_tag)
        output += remaining[0, start_index]
        @inside_think_tag = true
        {remaining[(start_index + start_tag.size)..]? || "", output}
      else
        suffix_len = longest_suffix_prefix(remaining, start_tag)
        output += remaining[0, remaining.size - suffix_len]
        @pending_think_tag = suffix_len.zero? ? "" : remaining[(remaining.size - suffix_len), suffix_len]
        {"", output}
      end
    end

    # Longest suffix of `text` that is also a prefix of `tag` (used to hold back a
    # partial tag straddling a chunk boundary).
    private def longest_suffix_prefix(text : String, tag : String) : Int32
      max = Math.min(text.size, tag.size - 1)
      max.downto(1) do |len|
        return len if text.ends_with?(tag[0, len])
      end
      0
    end

    # Private streaming buffer for one tool call. Holds metadata plus the
    # progressively-accumulated arguments, then materializes an immutable
    # `ToolCall` in `to_message`.
    #
    # Two argument channels, mirroring the two wire shapes:
    # - raw partial-JSON String fragments (`append_fragment`): the streaming wire
    #   shape — each per-event fragment (e.g. `{"latit`, `ud`, `e": ...`) is
    #   individually unparseable, so we concatenate them and `JSON.parse` ONCE in
    #   `to_tool_call` (ruby_llm's behavior). Falls back to `{}` on empty/parse-error.
    # - already-parsed Hash arguments (`merge_arguments`): providers that hand us
    #   parsed args (e.g. Anthropic's non-delta `content_block`) merge hash-wise.
    # When any raw fragment was appended, the parsed-buffer wins (it is the
    # authoritative reconstruction of the streamed args).
    private class ToolCallBuffer
      getter id : String
      getter name : String
      property thought_signature : String?

      def initialize(@id : String, @name : String, @thought_signature : String? = nil)
        @parsed = {} of String => JSON::Any
        @raw_buffer = nil.as(String?)
      end

      # Appends a raw partial-JSON String fragment (parsed once in `to_tool_call`).
      def append_fragment(fragment : String) : Nil
        @raw_buffer = (@raw_buffer || "") + fragment
      end

      # Merges parsed Hash arguments from a delta into the buffer.
      def merge_arguments(arguments : Hash(String, JSON::Any)) : Nil
        arguments.each { |k, v| @parsed[k] = v }
      end

      def to_tool_call : ToolCall
        ToolCall.new(
          id: @id,
          name: @name,
          arguments: resolved_arguments,
          thought_signature: @thought_signature
        )
      end

      # Prefers the concatenated raw-fragment stream (parsed once); falls back to the
      # merged parsed Hash when no raw fragments were seen. `{}` on empty/parse error.
      private def resolved_arguments : Hash(String, JSON::Any)
        raw = @raw_buffer
        return @parsed if raw.nil?
        return {} of String => JSON::Any if raw.empty?

        JSON.parse(raw).as_h? || {} of String => JSON::Any
      rescue JSON::ParseException
        {} of String => JSON::Any
      end
    end
  end
end
