# ported from lib/ruby_llm/providers/gemini/media.rb @ ruby_llm 1.15.0
#
# Gemini media formatting -> the `parts` array of a content/role entry. Gemini
# represents content as a list of "parts" objects: `{text: ...}` for text,
# `{inline_data: {mime_type, data}}` for binary attachments (image/audio/pdf/video).
# Text-file attachments inline as a `{text: <file ...>}` part; document/unknown
# attachments raise UnsupportedAttachmentError.
#
# DEFERRED: build_response_content / build_inline_attachment / build_file_attachment
# (the *inbound* parse of Gemini parts back into a Content). That is response-side
# (Chat parsing), not the outbound media formatting this gap covers; tracked here
# and in PORTING.md.
require "json"
require "../gemini"

module CrystalLLM
  module Providers
    class Gemini < Provider
      # Handles Gemini content -> parts formatting (text paths only — see header).
      module Media
        extend self

        # Returns the Gemini `parts` value for a message's content. Mirrors
        # ruby_llm's `Media.format_content`, which returns either a single part
        # (Raw passthrough) or an Array of part objects. The Crystal port always
        # returns an Array(JSON::Any) of parts (the Raw value is wrapped if it is
        # not already an array) so callers can `concat` uniformly.
        def format_content(content : String | Content | Content::Raw | Nil) : Array(JSON::Any)
          case content
          when Content::Raw
            raw = content.value
            raw.as_a? || [raw]
          when Nil
            [format_text("")]
          when String
            [format_text(content)]
          when Content
            format_rich_content(content)
          else
            [format_text(content.to_s)]
          end
        end

        # Builds a single `{text: ...}` part.
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
