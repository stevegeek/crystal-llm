# ported from lib/ruby_llm/content.rb @ ruby_llm 1.16.0
require "json"
require "./attachment"

module CrystalLLM
  # Accepted shapes for the `with:`/attachments argument. ruby_llm normalises a
  # single source, an array of sources, or a hash whose VALUES are sources (the
  # keys are decorative). The same three shapes are modelled here as a union.
  alias Attachable = Source | Array(Source) | Hash(String, Source) | Hash(String, Array(Source))

  # The content sent to or received from an LLM: text plus zero or more attachments.
  class Content
    getter text : String?
    getter attachments : Array(Attachment)

    def initialize(@text : String? = nil, attachments : Attachable? = nil)
      @attachments = [] of Attachment
      process_attachments(attachments)
      if @text.nil? && @attachments.empty?
        raise ArgumentError.new("Text and attachments cannot be both nil")
      end
    end

    # Overload for a pre-built `Attachment` array — a provider rebuilding a
    # `Content` from already-decoded attachments (e.g. Gemini's inbound
    # `build_response_content`, which decodes `inlineData`/`fileData` parts into
    # `Attachment`s directly). Assigned as-is, bypassing `process_attachments`
    # (there is nothing left to wrap/validate-as-Source). Mirrors ruby_llm's
    # positional `Content.new(text, attachments)` call in gemini/media.rb (commit
    # 9a08dd1c) — `Attachable` (the public `with:` argument type) intentionally
    # doesn't include `Attachment`, so this narrower overload exists for the
    # already-decoded-attachments case instead of widening the public type.
    def initialize(@text : String?, attachments : Array(Attachment))
      @attachments = attachments
      if @text.nil? && @attachments.empty?
        raise ArgumentError.new("Text and attachments cannot be both nil")
      end
    end

    # `source` may be a plain `Source` (String/Path/IO) or an existing `Attachment`
    # (ruby_llm 9a08dd1c) — reusing an already-loaded Attachment avoids re-reading
    # its bytes. See `build_attachment`.
    def add_attachment(source : Source | Attachment, filename : String? = nil) : self
      @attachments << build_attachment(source, filename: filename)
      self
    end

    # True when there is no text (nil or empty) and no attachments (ruby_llm a6a02653).
    def empty? : Bool
      @attachments.empty? && (@text || "").empty?
    end

    # Bare text (no attachments) formats to the String; otherwise to self.
    def format : String | Content
      if (t = @text) && @attachments.empty?
        t
      else
        self
      end
    end

    # For persistence.
    def to_h
      {text: @text, attachments: @attachments.map(&.to_h)}
    end

    # An existing `Attachment` is reused as-is; it is only re-wrapped (via its
    # `source`) when a new `filename` is given. Any other `Source` is wrapped in a
    # fresh `Attachment`. Mirrors ruby_llm's `build_attachment` (commit 9a08dd1c).
    private def build_attachment(source : Source | Attachment, filename : String? = nil) : Attachment
      if source.is_a?(Attachment)
        return source unless filename

        return Attachment.new(source.source, filename: filename)
      end

      Attachment.new(source, filename: filename)
    end

    private def process_attachments(attachments : Attachable?) : Nil
      case attachments
      when Nil
        # nothing to do
      when Hash
        attachments.each_value { |value| process_one_or_many(value) }
      else
        process_one_or_many(attachments)
      end
    end

    private def process_one_or_many(item : Source | Array(Source)) : Nil
      case item
      when Array
        item.each { |file| add_unless_blank(file) }
      else
        add_unless_blank(item)
      end
    end

    private def add_unless_blank(file : Source) : Nil
      return if file.is_a?(String) && file.strip.empty?

      add_attachment(file)
    end

    # Wraps a provider-specific payload that should bypass CrystalLLM formatting.
    class Raw
      getter value : JSON::Any

      def initialize(@value : JSON::Any)
      end

      def format : JSON::Any
        @value
      end

      def to_h : JSON::Any
        @value
      end
    end
  end
end
