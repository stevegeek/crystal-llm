# ported from lib/ruby_llm/providers/gemini/images.rb @ ruby_llm 1.16.0
#
# Gemini (Imagen) image-generation hooks (images_url / render_image_payload /
# parse_image_response), reopening Providers::Gemini. Gemini uses the Imagen
# `:predict` endpoint with an `instances` array (each `{prompt}`) and a
# `parameters` object (`{sampleCount: 1}`), and returns `predictions[0]` carrying
# `bytesBase64Encoded` + `mimeType` (base64 inline image; no url path).
#
# Structural template: providers/openai/images.cr. The payload/parse SHAPES follow
# gemini/images.rb (NOT the OpenAI wire shape).
#
# Divergences from ruby_llm:
# - `response.body` is a raw JSON String (Crest); parse JSON.parses it.
# - The `@model` ivar pattern: ruby_llm's `render_image_payload` assigns `@model`
#   which `images_url` then reads to build `models/<model>:predict`. The port mirrors
#   this with the already-established `@model_id` ivar (set in render_image_payload,
#   read in images_url) — the same coupling as completion_url/render_payload in
#   gemini/chat.cr. images_url raises if render hasn't run first (matching the Ruby
#   ordering: render runs before url in Provider#paint).
# - `size` is IGNORED (Gemini does not support image-size customization). ruby_llm
#   logs a debug line; the port logs the same via CrystalLLM.logger.debug.
# - `params` is accepted (the port's wire shape) but Gemini's render ignores it —
#   ruby_llm's gemini render_image_payload likewise ignores `params` (no `.merge`).
# - Gemini has no image-EDIT path: `with:`/`mask:` are unsupported. The base
#   `validate_paint_inputs!` (in provider_media.cr) already raises
#   UnsupportedAttachmentError on any with:/mask:, so Gemini does NOT override it.
require "json"
require "../gemini"
require "../../provider_media"
require "../../image"
require "../../content"
require "../../attachment"

module CrystalLLM
  module Providers
    class Gemini < Provider
      # rubocop-equivalent: with:/mask: are unused (Gemini has no edit path), but the
      # hook signature must match Provider#images_url.
      def images_url(with attachments : Attachable?, mask : Source?) : String
        model = @model_id || raise Error.new(
          "Gemini images_url requires render_image_payload to set the model first"
        )
        "models/#{model}:predict"
      end

      def render_image_payload(prompt : String, model : String, size : String,
                               with attachments : Attachable?, mask : Source?,
                               params : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        CrystalLLM.logger.debug do
          "Ignoring size #{size}. Gemini does not support image size customization."
        end
        @model_id = model

        instances = [
          JSON::Any.new({"prompt" => JSON::Any.new(prompt)} of String => JSON::Any),
        ]
        {
          "instances"  => JSON::Any.new(instances),
          "parameters" => JSON::Any.new({"sampleCount" => JSON::Any.new(1_i64)} of String => JSON::Any),
        } of String => JSON::Any
      end

      def parse_image_response(response : Crest::Response, model : String) : Image
        data = JSON.parse(response.body)

        rows = data["predictions"]?.try(&.as_a?) || [] of JSON::Any
        image_data = rows.first?.try(&.as_h?)

        unless image_data && image_data.has_key?("bytesBase64Encoded")
          raise Error.new(nil, "Unexpected response format from Gemini image generation API")
        end

        mime_type = image_data["mimeType"]?.try(&.as_s?) || "image/png"
        base64_data = image_data["bytesBase64Encoded"].as_s

        Image.new(
          data: base64_data,
          mime_type: mime_type,
          model_id: model
        )
      end
    end
  end
end
