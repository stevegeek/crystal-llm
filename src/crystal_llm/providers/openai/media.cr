# ported from lib/ruby_llm/providers/openai/media.rb @ ruby_llm 1.16.0
#
# Formats a Content's text + attachments into OpenAI chat content parts:
#   image -> {type:"image_url", image_url:{url: data-or-source-URL}}
#   audio -> {type:"input_audio", input_audio:{data: base64, format: ...}}
#   pdf   -> {type:"file", file:{filename, file_data: data-URL}}
#   text  -> {type:"text", text: <file ...>...}
#
# Divergences from ruby_llm:
#   - The Ruby `document_attachments:`/`image_attachments:`/`audio_attachments:`
#     gate keywords (used by OpenAI-compatible providers to disable a media kind)
#     are ported as plain method arguments with the same defaults
#     (document_attachments: "pdf", image/audio enabled). chat.cr does not pass
#     them yet, so the defaults apply — matching the base OpenAI behaviour.
#   - Ruby returns a String for bare text but an Array for attachment-bearing
#     content; that union is `JSON::Any` here (a String, or a JSON array of part
#     objects). The chat caller assigns it straight into entry["content"].
require "json"
require "../openai"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      # Handles formatting of media content (images, audio, pdf, text) for OpenAI APIs.
      module Media
        extend self

        # Returns the wire form of a message's content for the OpenAI chat API.
        # For plain text this is the bare String; richer shapes are JSON values.
        def format_content(content : String | Content | Content::Raw | Nil,
                           document_attachments : String = "pdf",
                           image_attachments : Bool = true,
                           audio_attachments : Bool = true) : JSON::Any
          case content
          when Content::Raw
            content.value
          when Nil
            JSON::Any.new(nil)
          when String
            JSON::Any.new(content)
          when Content
            format_rich_content(content, document_attachments, image_attachments, audio_attachments)
          else
            JSON::Any.new(content.to_s)
          end
        end

        # Dispatches a single attachment to the matching OpenAI content part.
        def format_attachment(attachment : Attachment,
                              document_attachments : String = "pdf",
                              image_attachments : Bool = true,
                              audio_attachments : Bool = true) : JSON::Any
          case attachment.type
          when :image
            raise UnsupportedAttachmentError.new(attachment.mime_type) unless image_attachments
            format_image(attachment)
          when :audio
            raise UnsupportedAttachmentError.new(attachment.mime_type) unless audio_attachments
            format_audio(attachment)
          when :pdf, :document
            format_document_attachment(attachment, document_attachments)
          when :text
            format_text_file(attachment)
          else
            raise UnsupportedAttachmentError.new(attachment.mime_type)
          end
        end

        # `{type:"image_url", image_url:{url: ...}}`. URL sources pass through;
        # otherwise a `data:` URL carrying the base64 bytes.
        def format_image(image : Attachment) : JSON::Any
          url = image.url? ? image.source.to_s : image.for_llm
          JSON::Any.new({
            "type"      => JSON::Any.new("image_url"),
            "image_url" => JSON::Any.new({"url" => JSON::Any.new(url)} of String => JSON::Any),
          } of String => JSON::Any)
        end

        # `{type:"file", file:{filename, file_data: data-URL}}`.
        def format_document(document : Attachment) : JSON::Any
          JSON::Any.new({
            "type" => JSON::Any.new("file"),
            "file" => JSON::Any.new({
              "filename"  => JSON::Any.new(document.filename),
              "file_data" => JSON::Any.new(document.for_llm),
            } of String => JSON::Any),
          } of String => JSON::Any)
        end

        # PDFs format as documents.
        def format_pdf(pdf : Attachment) : JSON::Any
          format_document(pdf)
        end

        # A text-file attachment as a plain text part (the `<file ...>` wrapper).
        def format_text_file(text_file : Attachment) : JSON::Any
          JSON::Any.new({
            "type" => JSON::Any.new("text"),
            "text" => JSON::Any.new(text_file.for_llm),
          } of String => JSON::Any)
        end

        # `{type:"input_audio", input_audio:{data: base64, format: ...}}`.
        def format_audio(audio : Attachment) : JSON::Any
          JSON::Any.new({
            "type"        => JSON::Any.new("input_audio"),
            "input_audio" => JSON::Any.new({
              "data"   => JSON::Any.new(audio.encoded),
              "format" => JSON::Any.new(audio.format),
            } of String => JSON::Any),
          } of String => JSON::Any)
        end

        # A `{type:"text", text:...}` content part.
        def format_text(text : String) : JSON::Any
          JSON::Any.new({
            "type" => JSON::Any.new("text"),
            "text" => JSON::Any.new(text),
          } of String => JSON::Any)
        end

        # Applies the document strategy: "all" sends every document, "pdf" only PDFs.
        def format_document_attachment(attachment : Attachment, strategy : String) : JSON::Any
          return format_document(attachment) if strategy == "all"
          return format_document(attachment) if strategy == "pdf" && attachment.pdf?

          raise UnsupportedAttachmentError.new(attachment.mime_type)
        end

        private def format_rich_content(content : Content, document_attachments : String,
                                        image_attachments : Bool, audio_attachments : Bool) : JSON::Any
          if content.attachments.empty?
            return JSON::Any.new(content.text)
          end

          parts = [] of JSON::Any
          if text = content.text
            parts << format_text(text)
          end
          content.attachments.each do |attachment|
            parts << format_attachment(
              attachment,
              document_attachments: document_attachments,
              image_attachments: image_attachments,
              audio_attachments: audio_attachments
            )
          end
          JSON::Any.new(parts)
        end
      end
    end
  end
end
