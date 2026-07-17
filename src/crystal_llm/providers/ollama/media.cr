# ported from lib/ruby_llm/providers/ollama/media.rb @ ruby_llm 1.15.0
#
# Ollama media formatting. Ollama is OpenAI-compatible, so most attachment types
# delegate to OpenAI::Media. The only divergence is the image part shape: Ollama
# wants a nested `{url, detail: "auto"}` object (vs OpenAI's identical nested
# object, so in practice Ollama uses the same nested form). The upstream Ruby
# version of this file calls `Ollama::Media.format_image` which wraps with
# `detail: "auto"` — identical to OpenAI's default behavior. Ollama does NOT
# support audio attachments (raises UnsupportedAttachmentError).
#
# Divergences from ruby_llm:
# - Ruby's `format_content` returns either a String (bare text) or an Array of
#   parts; Crystal uses JSON::Any throughout (a JSON string or JSON array).
# - `format_image` returns `{type:"image_url", image_url:{url, detail:"auto"}}`;
#   OpenAI::Media.format_image returns `{type:"image_url", image_url:{url}}` (no
#   detail key). The Ollama wire shape adds `detail: "auto"` — ported faithfully.
# - No audio / document support: both raise UnsupportedAttachmentError.
require "json"
require "../ollama"

module CrystalLLM
  module Providers
    class Ollama < OpenAI
      # Handles formatting of media content (images, text-files) for Ollama APIs.
      module Media
        extend self

        # Returns the wire form of a message's content for the Ollama chat API.
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

        # Ollama image part: `{type:"image_url", image_url:{url, detail:"auto"}}`.
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

      # Override the provider's format_content hook (called by OpenAI chat.cr's
      # format_messages) to use Ollama's media module instead of OpenAI::Media.
      def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
        Media.format_content(content)
      end
    end
  end
end
