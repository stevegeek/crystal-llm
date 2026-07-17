# ported from lib/ruby_llm/providers/gpustack/media.rb @ ruby_llm 1.16.0
#
# GPUStack media formatting. GPUStack is OpenAI-compatible ("based on Ollama").
# Its image part shape matches Ollama's: `{type:"image_url", image_url:{url,
# detail:"auto"}}`. Audio and text-file parts delegate to OpenAI::Media.
# Document attachments are NOT supported (raise UnsupportedAttachmentError).
#
# Divergences from ruby_llm:
# - Ruby's `format_content` returns String | Array; Crystal uses JSON::Any.
# - `format_image` adds `detail: "auto"` (matching the Ruby upstream).
require "json"
require "../gpustack"

module CrystalLLM
  module Providers
    class GPUStack < OpenAI
      # Handles formatting of media content (images, text-files) for GPUStack APIs.
      module Media
        extend self

        # Returns the wire form of a message's content for the GPUStack chat API.
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

        # GPUStack image part: `{type:"image_url", image_url:{url, detail:"auto"}}`.
        def format_image(image : Attachment) : JSON::Any
          JSON::Any.new({
            "type"      => JSON::Any.new("image_url"),
            "image_url" => JSON::Any.new({
              "url"    => JSON::Any.new(image.for_llm),
              "detail" => JSON::Any.new("auto"),
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
            when :text
              parts << OpenAI::Media.format_text_file(attachment)
            else
              raise UnsupportedAttachmentError.new(attachment.mime_type)
            end
          end
          JSON::Any.new(parts)
        end
      end

      # Override the provider's format_content hook to use GPUStack's media module.
      def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
        Media.format_content(content)
      end
    end
  end
end
