# ported from lib/ruby_llm/content.rb @ ruby_llm 1.15.0
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

    def add_attachment(source : Source, filename : String? = nil) : self
      @attachments << Attachment.new(source, filename: filename)
      self
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
