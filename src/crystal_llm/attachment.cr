# ported from lib/ruby_llm/attachment.rb @ ruby_llm 1.15.0
require "base64"
require "uri"
require "crest"
require "./mime_type"

module CrystalLLM
  # A file attachment source: a URL or local-path String, a `Path`, or an `IO`.
  # (ruby_llm also accepts ActiveStorage objects — those live in crystal-llm-marten.)
  alias Source = String | ::Path | ::IO

  # A file attachment for a chat message.
  class Attachment
    getter source : Source
    getter filename : String?
    getter mime_type : String

    URL_RE = %r{^https?://}

    DOCUMENT_EXTENSIONS = %w[
      doc docx dot key numbers odp ods odt pages pot pps ppt pptx rtf xls xlsx
    ]

    def initialize(@source : Source, filename : String? = nil)
      @filename = filename || source_filename
      @content = nil.as(Bytes?)
      @mime_type = determine_mime_type
    end

    def url? : Bool
      s = @source
      s.is_a?(String) && !(s =~ URL_RE).nil?
    end

    def path? : Bool
      @source.is_a?(::Path) || (@source.is_a?(String) && !url?)
    end

    def io_like? : Bool
      @source.is_a?(::IO)
    end

    # The attachment's bytes, loaded (and memoized) from the source.
    def content : Bytes?
      cached = @content
      return cached if cached

      @content =
        if url?
          Crest.get(@source.to_s).body.to_slice
        elsif path?
          File.open(@source.to_s, "rb", &.getb_to_end)
        elsif io_like?
          read_io(@source.as(::IO))
        else
          CrystalLLM.logger.warn { "Source is neither a URL, path, nor IO-like: #{@source.class}" }
          nil
        end
    end

    def encoded : String
      Base64.strict_encode(content || Bytes.empty)
    end

    def for_llm : String
      case type
      when :text
        "<file name='#{filename}' mime_type='#{mime_type}'>#{String.new(content || Bytes.empty)}</file>"
      else
        "data:#{mime_type};base64,#{encoded}"
      end
    end

    def type : Symbol
      return :image if image?
      return :video if video?
      return :audio if audio?
      return :pdf if pdf?
      return :text if text?
      return :document if document?

      :unknown
    end

    def image? : Bool
      MimeType.image?(mime_type)
    end

    def video? : Bool
      MimeType.video?(mime_type)
    end

    def audio? : Bool
      MimeType.audio?(mime_type)
    end

    def pdf? : Bool
      MimeType.pdf?(mime_type)
    end

    def text? : Bool
      MimeType.text?(mime_type)
    end

    def document? : Bool
      return false if pdf? || text?

      MimeType.document?(mime_type) || DOCUMENT_EXTENSIONS.includes?(extension)
    end

    def format : String
      case mime_type
      when "audio/mpeg"
        "mp3"
      when "audio/wav", "audio/wave", "audio/x-wav"
        "wav"
      else
        mime_type.split('/').last
      end
    end

    def extension : String?
      ext = File.extname(@filename.to_s).lchop('.').downcase
      ext.empty? ? nil : ext
    end

    # Serializable reference. ruby_llm stores the raw source; an IO can't be
    # serialized, so we record a filename reference for IO sources (see PORTING.md N8).
    def to_h
      {type: type, source: source_reference}
    end

    private def determine_mime_type : String
      mime = MimeType.for(name: @filename)
      mime = MimeType.for(content) if mime == "application/octet-stream"
      mime = "audio/wav" if mime == "audio/x-wav" # normalize WAV type
      mime
    end

    private def read_io(io : ::IO) : Bytes
      io.rewind if io.responds_to?(:rewind)
      io.getb_to_end
    end

    private def source_filename : String?
      if url?
        File.basename(URI.parse(@source.to_s).path)
      elsif path?
        File.basename(@source.to_s)
      elsif io_like?
        io = @source
        io.responds_to?(:path) ? File.basename(io.path.to_s) : "attachment"
      end
    end

    private def source_reference : String
      case s = @source
      when String then s
      when ::Path then s.to_s
      else             @filename || "attachment"
      end
    end
  end
end
