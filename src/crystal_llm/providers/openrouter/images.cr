# ported from lib/ruby_llm/providers/openrouter/images.rb @ ruby_llm 1.15.0
#
# OpenRouter image-generation hooks (images_url / render_image_payload /
# parse_image_response / build_image_from_url), reopening Providers::OpenRouter.
#
# Unlike OpenAI's dedicated images/generations endpoint, OpenRouter generates
# images through the *chat/completions* endpoint with `modalities: [image, text]`,
# and returns the result as an `images` array on the assistant message. The image
# is either a `data:` URL (inline base64) or a regular URL.
#
# Divergences from ruby_llm's openrouter/images.rb:
# - `response.body` is a raw JSON String (Crest); parse JSON.parses it. ruby_llm's
#   `response.body` is already a parsed Hash + `data.dig(...)` — here we walk
#   JSON::Any with `as_a?`/`as_h?` and explicit nil guards.
# - The `size` parameter is ignored by OpenRouter (same as ruby_llm). ruby_llm logs
#   a debug line via `RubyLLM.logger.debug`; this port omits the log call (the
#   top-level `CrystalLLM.logger` lives in crystal_llm.cr, which the media files are
#   built/specced in isolation from — requiring it would couple this file to the
#   whole entrypoint). The size-is-ignored behavior is unchanged; documented here.
# - `with:`/`mask:` (image editing) is NOT a path OpenRouter supports. ruby_llm
#   marks those args unused; the base `validate_paint_inputs!` (provider_media.cr)
#   already raises `UnsupportedAttachmentError` on any with:/mask:, so OpenRouter
#   does NOT override it (matching ruby_llm, which has no openrouter-specific
#   validation override). `render_image_payload` ignores them like ruby_llm does.
# - `params` is `Hash(String, JSON::Any)` (the port's wire shape). ruby_llm's
#   openrouter render_image_payload ignores `params` entirely; this port matches
#   that (params are accepted to satisfy the hook signature but not merged).
require "json"
require "../openrouter"
require "../../provider_media"
require "../../image"
require "../../content"
require "../../attachment"
require "../../error"

module CrystalLLM
  module Providers
    class OpenRouter < OpenAI
      # OpenRouter generates images via the chat completions endpoint (not a
      # dedicated images endpoint). with:/mask: are ignored (no edit path).
      def images_url(with attachments : Attachable?, mask : Source?) : String
        "chat/completions"
      end

      # Renders the chat-completions payload that requests an image. `size` is
      # ignored by OpenRouter (documented divergence above); `with`/`mask`/`params`
      # are accepted for signature parity but not used (matching ruby_llm).
      def render_image_payload(prompt : String, model : String, size : String,
                               with attachments : Attachable?, mask : Source?,
                               params : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        message = {
          "role"    => JSON::Any.new("user"),
          "content" => JSON::Any.new(prompt),
        } of String => JSON::Any

        modalities = ["image", "text"].map { |name| JSON::Any.new(name) }

        {
          "model"      => JSON::Any.new(model),
          "messages"   => JSON::Any.new([JSON::Any.new(message)]),
          "modalities" => JSON::Any.new(modalities),
        } of String => JSON::Any
      end

      def parse_image_response(response : Crest::Response, model : String) : Image
        data = JSON.parse(response.body)

        choice = data["choices"]?.try(&.as_a?).try(&.first?).try(&.as_h?)
        message = choice.try { |entry| entry["message"]? }.try(&.as_h?)

        images = message.try { |msg| msg["images"]? }.try(&.as_a?)
        if images.nil? || images.empty?
          raise Error.new(nil, "Unexpected response format from OpenRouter image generation API")
        end

        image_data = images.first.as_h?
        raise Error.new(nil, "Unexpected response format from OpenRouter image generation API") unless image_data

        # image_data.dig('image_url', 'url') || image_data['url']
        image_url = image_data["image_url"]?.try(&.as_h?).try { |url_obj| url_obj["url"]? }.try(&.as_s?)
        image_url ||= image_data["url"]?.try(&.as_s?)

        raise Error.new(nil, "No image URL found in OpenRouter response") unless image_url

        build_image_from_url(image_url, model)
      end

      # Builds an Image from either a `data:` URL (inline base64) or a regular URL.
      # Mirrors ruby_llm's `build_image_from_url`.
      def build_image_from_url(image_url : String, model : String) : Image
        if image_url.starts_with?("data:")
          # Parse data URL format: data:image/png;base64,<data>
          match = image_url.match(/^data:([^;]+);base64,(.+)$/)
          raise Error.new(nil, "Invalid data URL format from OpenRouter") unless match

          Image.new(
            data: match[2],
            mime_type: match[1],
            model_id: model,
          )
        else
          Image.new(
            url: image_url,
            mime_type: "image/png",
            model_id: model,
          )
        end
      end
    end
  end
end
