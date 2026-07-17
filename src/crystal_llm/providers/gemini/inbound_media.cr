# ported from lib/ruby_llm/providers/gemini/media.rb @ ruby_llm 1.15.0
#   (the inbound / response-side methods: build_response_content /
#    build_inline_attachment / build_file_attachment / attachment_filename)
#
# Gemini response parts can carry binary attachments (`inlineData` and `fileData`)
# in addition to text. This file ports the four methods that rebuild a
# `CrystalLLM::Content` (or a plain `String`) from a Gemini `parts` array so
# `parse_completion_response` reconstructs the full content instead of collapsing
# to text-only.
#
# Divergences from ruby_llm:
# - Ruby uses `Base64.decode64` (lenient); Crystal's `Base64.decode` is strict by
#   default but we use `Base64.decode(encoded, whitespace: :remove)` — equivalent
#   in practice. Decode errors are caught and logged, returning nil (same behavior).
# - Ruby's `StringIO.new(decoded)` becomes an `IO::Memory.new(Bytes)` in Crystal.
# - The `attachment_filename` logic is ported verbatim: "jpg" for "jpeg",
#   "txt" for "plain", `+` → `.` in sub-types (e.g. "svg+xml" → "svg.xml").
# - `build_response_content` returns `String | Content | Nil`:
#   - all-text parts → joined String (or nil when empty)
#   - any inline/file attachment → `Content.new(text:, attachments:)`
#   Mirrors ruby_llm's return type (`String | Content | nil`).
require "json"
require "base64"
require "../gemini"

module CrystalLLM
  module Providers
    class Gemini < Provider
      # Rebuilds the response content from a Gemini `parts` array. Returns:
      #   - nil  when all parts are empty or non-text/data
      #   - String  when all non-thought content is text-only (no attachments)
      #   - Content when any attachment (inlineData or fileData) is present
      # Mirrors ruby_llm's `Gemini#build_response_content`.
      def build_response_content(parts : Array(JSON::Any)) : String | Content | Nil
        text_parts, built_attachments = collect_parts(parts)

        joined_text = text_parts.join
        text = joined_text.empty? ? nil : joined_text

        return text if built_attachments.empty?

        # Build a Content and push the pre-built Attachment objects directly
        # (Attachment is not a Source, so we bypass Content#add_attachment).
        content = Content.new(text: text || "")
        built_attachments.each { |attachment| content.attachments << attachment }
        content
      rescue ex
        CrystalLLM.logger.warn { "build_response_content failed: #{ex.message}" }
        nil
      end

      # Iterates over parts and separates text strings from decoded attachments.
      private def collect_parts(parts : Array(JSON::Any)) : Tuple(Array(String), Array(Attachment))
        text_parts = [] of String
        built_attachments = [] of Attachment

        parts.each_with_index do |part_any, index|
          part = part_any.as_h? || next
          if t = part["text"]?.try(&.as_s?)
            text_parts << t
          elsif inline = part["inlineData"]?.try(&.as_h?)
            attachment = build_inline_attachment(inline, index)
            built_attachments << attachment if attachment
          elsif file = part["fileData"]?.try(&.as_h?)
            attachment = build_file_attachment(file, index)
            built_attachments << attachment if attachment
          end
        end

        {text_parts, built_attachments}
      end

      # Decodes a Gemini `inlineData` hash into an `Attachment`. Returns nil on
      # error (e.g. missing data or invalid Base64). Mirrors ruby_llm's
      # `build_inline_attachment`.
      def build_inline_attachment(inline_data : Hash(String, JSON::Any), index : Int32) : Attachment?
        encoded = inline_data["data"]?.try(&.as_s?)
        return nil unless encoded

        mime_type = inline_data["mimeType"]?.try(&.as_s?)
        decoded = Base64.decode(encoded)
        io = IO::Memory.new(decoded)
        io.rewind
        filename = attachment_filename(mime_type, index)
        Attachment.new(io, filename: filename)
      rescue ex : Exception
        CrystalLLM.logger.warn { "Failed to decode Gemini inline data attachment: #{ex.message}" }
        nil
      end

      # Builds an `Attachment` from a Gemini `fileData` hash (a URI reference).
      # Returns nil when the URI is absent. Mirrors ruby_llm's `build_file_attachment`.
      def build_file_attachment(file_data : Hash(String, JSON::Any), index : Int32) : Attachment?
        uri = file_data["fileUri"]?.try(&.as_s?)
        return nil unless uri

        filename = file_data["filename"]?.try(&.as_s?) ||
                   attachment_filename(file_data["mimeType"]?.try(&.as_s?), index)
        Attachment.new(uri, filename: filename)
      end

      # Returns a filename for a Gemini attachment. Mirrors ruby_llm's
      # `attachment_filename`: "jpg" for "jpeg", "txt" for "plain",
      # `+` → `.` in sub-types. Falls back to plain index name when mime_type is nil.
      def attachment_filename(mime_type : String?, index : Int32) : String
        unless mime_type
          return "gemini_attachment_#{index + 1}"
        end

        extension = mime_type.split('/').last.to_s
        extension = "jpg" if extension == "jpeg"
        extension = "txt" if extension == "plain"
        extension = extension.tr("+", ".")
        "gemini_attachment_#{index + 1}.#{extension}"
      end
    end
  end
end
