# ported from lib/ruby_llm/providers/azure/media.rb @ ruby_llm 1.15.0
#
# Azure media formatting. Azure is OpenAI-compatible but has its own image part
# shape: `{type:"image_url", image_url:{url}}` — similar to OpenAI but without
# the `detail` key. Audio and text-file parts delegate to OpenAI::Media. PDF and
# other document attachments are NOT supported (raise UnsupportedAttachmentError).
#
# Divergences from ruby_llm:
# - Ruby's `format_content` returns String | Array; Crystal uses JSON::Any.
# - `format_image` uses `{image_url: {url: image.for_llm}}` (always the data-URL,
#   no url? check) — mirrors azure/media.rb which calls `image.for_llm` directly.
require "json"
require "../azure"

module CrystalLLM
  module Providers
    class Azure < OpenAI
      # Handles formatting of media content (images, audio, text-files) for Azure APIs.
      module Media
        extend self

        # Returns the wire form of a message's content for the Azure chat API.
        def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
          case content
          when Content::Raw
            content.value
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

        # Azure image part: `{type:"image_url", image_url:{url}}` (no detail key).
        def format_image(image : Attachment) : JSON::Any
          JSON::Any.new({
            "type"      => JSON::Any.new("image_url"),
            "image_url" => JSON::Any.new({
              "url" => JSON::Any.new(image.for_llm),
            } of String => JSON::Any),
          } of String => JSON::Any)
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
              parts << format_image(attachment)
            when :audio
              parts << OpenAI::Media.format_audio(attachment)
            when :text
              parts << OpenAI::Media.format_text_file(attachment)
            else
              raise UnsupportedAttachmentError.new(attachment.mime_type)
            end
          end
          JSON::Any.new(parts)
        end
      end
    end
  end
end
