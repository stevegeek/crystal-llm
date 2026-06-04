# ported from lib/ruby_llm/providers/gemini/media.rb @ ruby_llm 1.15.0
#   (Gemini wire format, used by VertexAI — see providers/vertexai.cr header)
#
# DEFERRED (with the attachment-provider work): rich attachment formatting —
# inline_data (image/audio/pdf) and fileData parts — depends on Attachment#encoded /
# #mime_type / #for_llm, part of the not-yet-ported attachment surface. Only the chat
# text paths are ported (bare String text part, Content::Raw passthrough, Hash/Array
# -> JSON text part, plain text Content with no attachments). A Content carrying
# attachments raises a clear "deferred" error rather than silently dropping them.
require "json"
require "../vertexai"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      # Gemini-format media: a message's content becomes an Array of `part` objects
      # ({"text" => ...} / inline_data / fileData). Text paths only (see file header).
      module Media
        extend self

        # Returns the Gemini wire `parts` for a message's content. Always an Array of
        # JSON::Any part objects (Content::Raw is the one passthrough that may not be).
        def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
          case content
          when Content::Raw
            content.value
          when Nil
            JSON::Any.new([format_text("")])
          when String
            JSON::Any.new([format_text(content)])
          when Content
            format_rich_content(content)
          else
            JSON::Any.new([format_text(content.to_s)])
          end
        end

        # A single `{"text" => text}` part.
        def format_text(text : String) : JSON::Any
          JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any)
        end

        private def format_rich_content(content : Content) : JSON::Any
          if content.attachments.empty?
            text = content.text || ""
            return JSON::Any.new([format_text(text)])
          end

          raise NotImplementedError.new(
            "Vertex AI / Gemini attachment formatting (inline_data / fileData parts) is " \
            "deferred to the attachment-provider port (needs Attachment#encoded/#mime_type/" \
            "#for_llm). See providers/vertexai/media.cr."
          )
        end
      end
    end
  end
end
