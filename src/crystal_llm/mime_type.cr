# ported from lib/ruby_llm/mime_type.rb @ ruby_llm 1.16.0
require "mime"

module CrystalLLM
  # Handles MIME types. ruby_llm delegates detection to the marcel gem; we use
  # the stdlib `MIME` module (filename → type) plus a small magic-byte sniffer
  # for the binary formats attachments care about.
  module MimeType
    extend self

    # Extensions marcel (upstream's mime detector) knows but Crystal's stdlib
    # `MIME` DB doesn't. Discovered porting ruby_llm 1.16.0 / 329cfe4f ("keep text
    # attachments as text"), whose Bedrock/Perplexity specs attach a `.md` file and
    # expect it to classify as text; `::MIME.from_filename?("x.md")` returns nil,
    # so without this fallback a markdown attachment resolves to `:unknown` and is
    # rejected by every provider instead of being treated as text.
    EXTENSION_FALLBACKS = {
      "md" => "text/markdown",
    }

    def for(bytes : Bytes? = nil, name : String? = nil, declared_type : String? = nil) : String
      if bytes && (sniffed = sniff(bytes))
        return sniffed
      end
      if name && (from_name = ::MIME.from_filename?(name))
        return from_name
      end
      if name && (fallback = EXTENSION_FALLBACKS[extension(name)]?)
        return fallback
      end
      declared_type || "application/octet-stream"
    end

    # The lowercased extension (without the leading dot), or "" when absent.
    private def extension(name : String) : String
      ext = ::File.extname(name)
      ext.empty? ? "" : ext[1..].downcase
    end

    def image?(type : String) : Bool
      type.starts_with?("image/")
    end

    def video?(type : String) : Bool
      type.starts_with?("video/")
    end

    def audio?(type : String) : Bool
      type.starts_with?("audio/")
    end

    def pdf?(type : String) : Bool
      type == "application/pdf"
    end

    def document?(type : String) : Bool
      return false if pdf?(type) || text?(type)

      DOCUMENT_MIME_TYPES.includes?(type) ||
        DOCUMENT_MIME_PREFIXES.any? { |prefix| type.starts_with?(prefix) }
    end

    def text?(type : String) : Bool
      type.starts_with?("text/") ||
        TEXT_SUFFIXES.any? { |suffix| type.ends_with?(suffix) } ||
        NON_TEXT_PREFIX_TEXT_MIME_TYPES.includes?(type)
    end

    # Sniffs a handful of common binary formats from their leading bytes.
    private def sniff(bytes : Bytes) : String?
      return "image/png" if starts_with?(bytes, Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      return "image/jpeg" if starts_with?(bytes, Bytes[0xFF, 0xD8, 0xFF])
      return "image/gif" if starts_with?(bytes, "GIF87a".to_slice) || starts_with?(bytes, "GIF89a".to_slice)
      return "application/pdf" if starts_with?(bytes, "%PDF".to_slice)
      if starts_with?(bytes, "RIFF".to_slice) && bytes.size >= 12 && bytes[8, 4] == "WEBP".to_slice
        return "image/webp"
      end

      nil
    end

    private def starts_with?(bytes : Bytes, prefix : Bytes) : Bool
      bytes.size >= prefix.size && bytes[0, prefix.size] == prefix
    end

    # MIME types with a text/ prefix-like structured suffix that should be text.
    TEXT_SUFFIXES = ["+json", "+xml", "+html", "+yaml", "+csv", "+plain", "+javascript", "+svg"]

    # MIME types that don't have a text/ prefix but should be treated as text.
    NON_TEXT_PREFIX_TEXT_MIME_TYPES = [
      "application/json",
      "application/xml",
      "application/javascript",
      "application/ecmascript",
      "application/rtf",
      "application/sql",
      "application/x-sh",
      "application/x-csh",
      "application/x-httpd-php",
      "application/sdp",
      "application/sparql-query",
      "application/graphql",
      "application/yang",
      "application/mbox",
      "application/x-tex",
      "application/x-latex",
      "application/x-perl",
      "application/x-python",
      "application/x-tcl",
      "application/pgp-signature",
      "application/pgp-keys",
      "application/vnd.coffeescript",
      "application/vnd.dart",
      "application/vnd.oai.openapi",
      "application/vnd.zul",
      "application/x-yaml",
      "application/yaml",
      "application/toml",
    ]

    DOCUMENT_MIME_TYPES = [
      "application/msword",
      "application/rtf",
      "application/vnd.apple.keynote",
      "application/vnd.apple.numbers",
      "application/vnd.apple.pages",
      "application/vnd.google-apps.document",
      "application/vnd.google-apps.presentation",
      "application/vnd.google-apps.spreadsheet",
      "application/vnd.ms-excel",
      "application/vnd.ms-powerpoint",
    ]

    DOCUMENT_MIME_PREFIXES = [
      "application/vnd.openxmlformats-officedocument.",
      "application/vnd.oasis.opendocument.",
    ]
  end
end
