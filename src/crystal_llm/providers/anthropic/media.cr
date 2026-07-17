# ported from lib/ruby_llm/providers/anthropic/media.rb @ ruby_llm 1.15.0
#
# Formats content into Anthropic native content blocks:
#   image -> {type:"image", source:{type:"url"|"base64", ...}}
#   pdf   -> {type:"document", source:{type:"url"|"base64", ...}}
#   text  -> {type:"text", text: <file ...>...}
# Anything else (audio/video/document/unknown) raises UnsupportedAttachmentError.
#
# Divergence: ruby_llm's format_content returns either a single Hash (a text block)
# or an Array of blocks depending on the input; in Crystal that union is expressed as
# `JSON::Any` (a JSON object for a single block, a JSON array for multiple). Callers
# (chat.cr) branch on `.as_a?` the same way ruby_llm branches on `is_a?(Array)`.
require "json"
require "../anthropic"

module CrystalLLM
  module Providers
    class Anthropic < Provider
      # Handles formatting of media content for the Anthropic Messages API: text
      # plus image / pdf / text-file attachments (see `format_rich_content`).
      module Media
        extend self

        # The Anthropic content-block wire form of a message's content. Returns a
        # JSON array of blocks (or, for Content::Raw, whatever the raw value is).
        # Note: bare `Content` inside Providers::Anthropic resolves to the nested
        # Anthropic::Content factory (see content.cr); use CrystalLLM::Content for
        # the actual message content type.
        def format_content(content : String | CrystalLLM::Content | CrystalLLM::Content::Raw | Nil) : JSON::Any
          case content
          when CrystalLLM::Content::Raw
            content.value
          when Nil
            JSON::Any.new([format_text("")] of JSON::Any)
          when String
            JSON::Any.new([format_text(content)] of JSON::Any)
          when CrystalLLM::Content
            format_rich_content(content)
          else
            JSON::Any.new([format_text(content.to_s)] of JSON::Any)
          end
        end

        # A single `{type:"text", text:...}` block as a JSON::Any.
        def format_text(text : String) : JSON::Any
          JSON::Any.new({
            "type" => JSON::Any.new("text"),
            "text" => JSON::Any.new(text),
          } of String => JSON::Any)
        end

        # An `{type:"image", source:...}` block. URL sources use a `url` source;
        # otherwise a base64 source with the attachment's media_type + bytes.
        def format_image(image : Attachment) : JSON::Any
          source =
            if image.url?
              {
                "type" => JSON::Any.new("url"),
                "url"  => JSON::Any.new(image.source.to_s),
              } of String => JSON::Any
            else
              {
                "type"       => JSON::Any.new("base64"),
                "media_type" => JSON::Any.new(image.mime_type),
                "data"       => JSON::Any.new(image.encoded),
              } of String => JSON::Any
            end
          JSON::Any.new({
            "type"   => JSON::Any.new("image"),
            "source" => JSON::Any.new(source),
          } of String => JSON::Any)
        end

        # An `{type:"document", source:...}` block (PDFs), url or base64.
        def format_pdf(pdf : Attachment) : JSON::Any
          source =
            if pdf.url?
              {
                "type" => JSON::Any.new("url"),
                "url"  => JSON::Any.new(pdf.source.to_s),
              } of String => JSON::Any
            else
              {
                "type"       => JSON::Any.new("base64"),
                "media_type" => JSON::Any.new(pdf.mime_type),
                "data"       => JSON::Any.new(pdf.encoded),
              } of String => JSON::Any
            end
          JSON::Any.new({
            "type"   => JSON::Any.new("document"),
            "source" => JSON::Any.new(source),
          } of String => JSON::Any)
        end

        # A text-file attachment as a text block (the `<file ...>` wrapper).
        def format_text_file(text_file : Attachment) : JSON::Any
          format_text(text_file.for_llm)
        end

        private def format_rich_content(content : CrystalLLM::Content) : JSON::Any
          blocks = [] of JSON::Any
          if text = content.text
            blocks << format_text(text)
          end

          content.attachments.each do |attachment|
            case attachment.type
            when :image
              blocks << format_image(attachment)
            when :pdf
              blocks << format_pdf(attachment)
            when :text
              blocks << format_text_file(attachment)
            else
              raise UnsupportedAttachmentError.new(attachment.mime_type)
            end
          end

          JSON::Any.new(blocks)
        end
      end
    end
  end
end
