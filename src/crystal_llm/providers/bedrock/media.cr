# ported from lib/ruby_llm/providers/bedrock/media.rb @ ruby_llm 1.15.0
#
# Media formatting for Bedrock Converse content blocks. A single attachment becomes
# one Converse content block:
#   image          -> {image:    {format, source: {bytes: base64}}}
#   pdf / document  -> {document: {format, name, source: {bytes: base64}}}
#   text            -> {text: <file ...>}  (or a document block when the text file's
#                       extension/format is a supported document format)
#   anything else   -> raises UnsupportedAttachmentError
#
# Document blocks carry a `name`; Bedrock requires those names to be unique within a
# request, so they are de-duplicated against a caller-supplied `used_document_names`
# tally (ruby_llm threads this as the `used_document_names:` keyword across a payload).
#
# Divergences from ruby_llm:
# - ruby_llm's Media is a `module_function` module covering the whole render_content
#   dispatch (text / Hash / Array / Raw / Content). In the Crystal port that
#   higher-level dispatch already lives in bedrock/chat.cr (render_message_content /
#   render_text_content); this module ports only the per-attachment block builders
#   (render_attachment + friends), which chat.cr calls per attachment. Block builders
#   return JSON::Any (the Converse wire is camelCase String keys).
# - `attachment.encoded` is the base64 String (ruby_llm sends the same String; the AWS
#   SDK base64-decodes it, but the Converse JSON over HTTP carries the base64 text).
require "json"
require "../bedrock"

module CrystalLLM
  module Providers
    class Bedrock < Provider
      # Per-attachment Bedrock Converse block builders (see file header).
      module Media
        extend self

        # Bedrock Converse document formats (ruby_llm SUPPORTED_DOCUMENT_FORMATS).
        SUPPORTED_DOCUMENT_FORMATS = %w[pdf csv doc docx xls xlsx html txt md]

        # Builds the Converse content block for a single attachment, mutating
        # `used_document_names` to keep document names unique. Raises
        # UnsupportedAttachmentError for attachment kinds Bedrock can't carry.
        def render_attachment(attachment : Attachment,
                              used_document_names : Hash(String, Int32)) : JSON::Any
          case attachment.type
          when :image
            render_image_attachment(attachment)
          when :pdf, :document
            render_document_attachment(attachment, used_document_names)
          when :text
            render_text_attachment(attachment, used_document_names)
          else
            raise UnsupportedAttachmentError.new(attachment.mime_type)
          end
        end

        # `{image: {format, source: {bytes: base64}}}`.
        def render_image_attachment(attachment : Attachment) : JSON::Any
          JSON::Any.new({
            "image" => JSON::Any.new({
              "format" => JSON::Any.new(attachment.format),
              "source" => JSON::Any.new({
                "bytes" => JSON::Any.new(attachment.encoded),
              } of String => JSON::Any),
            } of String => JSON::Any),
          } of String => JSON::Any)
        end

        # A text-file attachment: a document block when its format is a supported
        # Bedrock document format, otherwise an inline `{text: <file ...>}` block.
        def render_text_attachment(attachment : Attachment,
                                   used_document_names : Hash(String, Int32)) : JSON::Any
          if supported_document_format?(attachment)
            return render_document_attachment(attachment, used_document_names)
          end

          JSON::Any.new({"text" => JSON::Any.new(attachment.for_llm)} of String => JSON::Any)
        end

        # `{document: {format, name, source: {bytes: base64}}}`. Raises when the
        # attachment's format is not a supported Bedrock document format.
        def render_document_attachment(attachment : Attachment,
                                       used_document_names : Hash(String, Int32)) : JSON::Any
          format = document_format(attachment)

          unless supported_document_format?(attachment)
            raise UnsupportedAttachmentError.new(attachment.mime_type)
          end

          document_name = unique_document_name(
            sanitize_document_name(attachment.filename), used_document_names
          )

          JSON::Any.new({
            "document" => JSON::Any.new({
              "format" => JSON::Any.new(format),
              "name"   => JSON::Any.new(document_name),
              "source" => JSON::Any.new({
                "bytes" => JSON::Any.new(attachment.encoded),
              } of String => JSON::Any),
            } of String => JSON::Any),
          } of String => JSON::Any)
        end

        def supported_document_format?(attachment : Attachment) : Bool
          SUPPORTED_DOCUMENT_FORMATS.includes?(document_format(attachment))
        end

        # The document format: the file extension if present, else the mime format.
        def document_format(attachment : Attachment) : String
          attachment.extension || attachment.format
        end

        # Strips the extension and replaces unsafe chars; "document" when empty.
        def sanitize_document_name(filename : String?) : String
          base = File.basename(filename.to_s, File.extname(filename.to_s))
          safe = base.gsub(/[^a-zA-Z0-9_-]/, '_')
          safe.empty? ? "document" : safe
        end

        # Returns `base_name` the first time it is seen; subsequent collisions get a
        # `_N` suffix. Mutates `used_names` to record the running count (ruby_llm parity).
        def unique_document_name(base_name : String, used_names : Hash(String, Int32)) : String
          count = used_names[base_name]? || 0
          used_names[base_name] = count + 1
          return base_name if count.zero?

          "#{base_name}_#{count + 1}"
        end
      end
    end
  end
end
