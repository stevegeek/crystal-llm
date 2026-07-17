# ported from lib/ruby_llm/providers/perplexity/media.rb @ ruby_llm 1.15.0
#
# Perplexity (Sonar) media formatting. Perplexity is OpenAI-compatible for chat,
# but extends the content-part vocabulary with a `file_url` part type for supported
# document attachments (PDF, doc, docx, txt, rtf). Image parts delegate to
# OpenAI::Media. Text-file attachments that match the supported-document list route
# to `format_document`; others fall back to OpenAI::Media.format_text_file.
#
# Divergences from ruby_llm:
# - Ruby's `format_content` returns String | Array; Crystal uses JSON::Any.
# - `SUPPORTED_DOCUMENT_EXTENSIONS` is a constant Array(String) (not a frozen Array
#   literal), matching Perplexity's wire-format requirements.
# - `format_document` raises UnsupportedAttachmentError for unsupported file types.
require "json"
require "../perplexity"

module CrystalLLM
  module Providers
    class Perplexity < OpenAI
      # Handles formatting of media content for Perplexity Sonar APIs.
      module Media
        extend self

        SUPPORTED_DOCUMENT_EXTENSIONS = %w[pdf doc docx txt rtf]

        # Returns the wire form of a message's content for the Perplexity chat API.
        def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
          case content
          when Content::Raw
            raw = content.value
            raw
          when Nil
            JSON::Any.new(nil)
          when String
            JSON::Any.new(content)
          when Content
            format_rich_content(content)
          else
            JSON::Any.new(content.to_s)
          end
        end

        # A `{type:"file_url", file_url:{url}}` part for supported document types.
        # Raises UnsupportedAttachmentError for unsupported document formats.
        def format_document(attachment : Attachment) : JSON::Any
          unless supported_file?(attachment)
            raise UnsupportedAttachmentError.new(attachment.mime_type)
          end

          url = attachment.url? ? attachment.source.to_s : attachment.encoded
          JSON::Any.new({
            "type"     => JSON::Any.new("file_url"),
            "file_url" => JSON::Any.new({
              "url" => JSON::Any.new(url),
            } of String => JSON::Any),
          } of String => JSON::Any)
        end

        # Routes a text-file attachment: if it matches the supported-document list,
        # format as a document (file_url); otherwise fall back to text_file inline.
        def format_text_attachment(attachment : Attachment) : JSON::Any
          if supported_file?(attachment)
            format_document(attachment)
          else
            OpenAI::Media.format_text_file(attachment)
          end
        end

        # True if the attachment is a PDF or has a SUPPORTED_DOCUMENT_EXTENSIONS extension.
        def supported_file?(attachment : Attachment) : Bool
          return true if attachment.pdf?

          SUPPORTED_DOCUMENT_EXTENSIONS.includes?(attachment.extension)
        end

        private def format_rich_content(content : Content) : JSON::Any
          if content.attachments.empty?
            return JSON::Any.new(content.text)
          end

          parts = [] of JSON::Any
          if text = content.text
            parts << OpenAI::Media.format_text(text)
          end
          content.attachments.each do |attachment|
            case attachment.type
            when :image
              parts << OpenAI::Media.format_image(attachment)
            when :pdf, :document
              parts << format_document(attachment)
            when :text
              parts << format_text_attachment(attachment)
            else
              raise UnsupportedAttachmentError.new(attachment.mime_type)
            end
          end
          JSON::Any.new(parts)
        end
      end

      # Override the provider's format_content hook to use Perplexity's media module.
      def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
        Media.format_content(content)
      end
    end
  end
end
