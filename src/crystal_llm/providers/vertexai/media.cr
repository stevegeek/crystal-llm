# ported from lib/ruby_llm/providers/gemini/media.rb @ ruby_llm 1.15.0
#   (Gemini wire format, used by VertexAI — see providers/vertexai.cr header)
#
# VertexAI uses the Gemini content wire format: a message's content becomes an Array of
# `part` objects. This ports Gemini's outbound Media.format_content:
#   text            -> {text: ...}
#   text-file attach -> {text: <file ...>}  (Attachment#for_llm)
#   image/audio/pdf/video -> {inline_data: {mime_type, data: base64}}
#   document / unknown    -> raises UnsupportedAttachmentError
#
# Note: ruby_llm's gemini/media.rb emits ONLY inline_data on the OUTBOUND side; the
# `fileData` ({fileUri}) parts are response-side parsing (build_file_attachment), which
# is inbound (DEFERRED with the Chat response parse — see below). So outbound parity is
# inline_data + text, matching Gemini::Media exactly.
#
# Divergences from ruby_llm / the Gemini Crystal port:
# - VertexAI::Media.format_content returns JSON::Any (wrapping an Array of parts), where
#   the Gemini port returns Array(JSON::Any). VertexAI's chat.cr (format_message_parts)
#   consumes a JSON::Any and unwraps with `.as_a? || [formatted]`; this preserves the
#   Content::Raw passthrough (which may be a non-array value) without re-wrapping.
# - Content with no attachments collapses to a single {text} part (ruby_llm builds the
#   same single-text parts array).
#
# DEFERRED (inbound, not this media gap): build_response_content / build_inline_attachment
# / build_file_attachment — parsing Gemini parts back into a Content (Chat response side).
require "json"
require "../vertexai"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      # Gemini-format media: a message's content becomes an Array of `part` objects
      # ({"text" => ...} / {"inline_data" => ...}). See file header.
      module Media
        extend self

        # Returns the Gemini wire `parts` for a message's content. Always a JSON::Any:
        # a JSON array of part objects, except Content::Raw which passes through verbatim.
        def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
          case content
          when Content::Raw
            content.value
          when Nil
            JSON::Any.new([format_text("")])
          when String
            JSON::Any.new([format_text(content)])
          when Content
            JSON::Any.new(format_rich_content(content))
          else
            JSON::Any.new([format_text(content.to_s)])
          end
        end

        # A single `{"text" => text}` part.
        def format_text(text : String) : JSON::Any
          JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any)
        end

        # Dispatches a single attachment: text-files inline as text; document/unknown
        # are unsupported; everything else (image/audio/pdf/video) -> inline_data.
        def format_content_attachment(attachment : Attachment) : JSON::Any
          case attachment.type
          when :text
            format_text_file(attachment)
          when :document, :unknown
            raise UnsupportedAttachmentError.new(attachment.mime_type)
          else
            format_attachment(attachment)
          end
        end

        # An `{inline_data: {mime_type, data: base64}}` part.
        def format_attachment(attachment : Attachment) : JSON::Any
          JSON::Any.new({
            "inline_data" => JSON::Any.new({
              "mime_type" => JSON::Any.new(attachment.mime_type),
              "data"      => JSON::Any.new(attachment.encoded),
            } of String => JSON::Any),
          } of String => JSON::Any)
        end

        # A text-file attachment as a `{text: <file ...>}` part.
        def format_text_file(text_file : Attachment) : JSON::Any
          format_text(text_file.for_llm)
        end

        private def format_rich_content(content : Content) : Array(JSON::Any)
          parts = [] of JSON::Any
          if text = content.text
            parts << format_text(text)
          end

          content.attachments.each do |attachment|
            parts << format_content_attachment(attachment)
          end

          parts
        end
      end
    end
  end
end
