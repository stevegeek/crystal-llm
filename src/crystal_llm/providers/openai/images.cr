# ported from lib/ruby_llm/providers/openai/images.rb @ ruby_llm 1.16.0
#
# OpenAI image-generation hooks (images_url / render_image_payload /
# parse_image_response / validate_paint_inputs!), reopening Providers::OpenAI.
#
# Divergences:
# - `response.body` is a raw JSON String (Crest); parse JSON.parses it.
# - The image *edit* path (with:/mask: → `images/edits`) uploads the reference
#   image(s) + optional mask as `multipart/form-data` via `Connection#post_multipart`
#   (ruby_llm's `render_edit_payload` + `build_upload_part(s)`). `render_image_edit_form`
#   builds the crest form; `render_image_payload` handles generation only. (Previously
#   DEFERRED while Connection sent a JSON body only.)
# - `params` is `Hash(String, JSON::Any)` (the port's wire shape), merged over the
#   base generation/edit payload (ruby_llm's `.merge(params)`).
require "json"
require "../openai"
require "../../provider_media"
require "../../image"
require "../../content"
require "../../attachment"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      def images_url(with attachments : Attachable?, mask : Source?) : String
        editing?(attachments, mask) ? "images/edits" : "images/generations"
      end

      def render_image_payload(prompt : String, model : String, size : String,
                               with _attachments : Attachable?, mask _mask : Source?,
                               params : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        payload = {
          "model"  => JSON::Any.new(model),
          "prompt" => JSON::Any.new(prompt),
          "n"      => JSON::Any.new(1_i64),
          "size"   => JSON::Any.new(size),
        } of String => JSON::Any
        params.each { |k, v| payload[k] = v }
        payload
      end

      # OpenAI supports image editing: this paint call edits whenever a reference
      # image (`with:`) or `mask:` is supplied.
      def editing_image?(with attachments : Attachable?, mask : Source?) : Bool
        editing?(attachments, mask)
      end

      # Builds the `images/edits` multipart form (ruby_llm's `render_edit_payload`):
      # the reference image(s) become `image[]` file parts, the optional mask a
      # `mask` part, alongside the scalar prompt/model/n fields and any extra params.
      def render_image_edit_form(prompt : String, model : String, size : String,
                                 with attachments : Attachable?, mask : Source?,
                                 params : Hash(String, JSON::Any)) : Hash(String, Crest::ParamsValue)
        form = {} of String => Crest::ParamsValue
        params.each { |k, v| form[k] = json_to_form_value(v) }
        form["model"] = model
        form["prompt"] = prompt
        form["n"] = 1_i64

        image_parts = build_upload_parts(attachments)
        image_parts.each_with_index do |part, index|
          form["image[#{index}]"] = part
        end

        if mask_source = mask
          form["mask"] = build_upload_part(mask_source)
        end

        form
      end

      # Builds a file part per non-blank source in *value* (ruby_llm's
      # `build_upload_parts`); blank string sources are skipped.
      private def build_upload_parts(value : Attachable?) : Array(File)
        each_source(value).compact_map do |source|
          next if blank_attachment?(source)

          build_upload_part(source)
        end
      end

      def parse_image_response(response : Crest::Response, model : String) : Image
        data = JSON.parse(response.body)

        rows = data["data"]?.try(&.as_a?) || [] of JSON::Any
        image_data = rows.first?.try(&.as_h?)

        raise Error.new(nil, "Unexpected response format from OpenAI image API") unless image_data

        usage = data["usage"]?.try(&.as_h?) || {} of String => JSON::Any

        Image.new(
          url: image_data["url"]?.try(&.as_s?),
          mime_type: "image/png", # DALL-E typically returns PNGs
          revised_prompt: image_data["revised_prompt"]?.try(&.as_s?),
          model_id: model,
          data: image_data["b64_json"]?.try(&.as_s?),
          usage: usage
        )
      end

      # OpenAI overrides the base validation: editing requires `with:` when `mask:`
      # is given (ruby_llm). The base raises on any with:/mask:; OpenAI permits them.
      def validate_paint_inputs!(with attachments : Attachable?, mask : Source?) : Nil
        return unless editing?(attachments, mask)

        if mask && !attachments?(attachments)
          raise ArgumentError.new("with: is required when mask: is provided")
        end
      end

      private def editing?(attachments : Attachable?, mask : Source?) : Bool
        attachments?(attachments) || !mask.nil?
      end

      private def attachments?(value : Attachable?) : Bool
        each_source(value).any? { |item| !blank_attachment?(item) }
      end

      private def blank_attachment?(value : Source) : Bool
        value.is_a?(String) && value.strip.empty?
      end

      # Flattens an Attachable (single / array / hash-of-sources) into the sources.
      private def each_source(value : Attachable?) : Array(Source)
        case value
        when Nil
          [] of Source
        when Array
          value.map(&.as(Source))
        when Hash
          out = [] of Source
          value.each_value do |v|
            case v
            when Array then v.each { |src| out << src }
            else            out << v.as(Source)
            end
          end
          out
        else
          [value.as(Source)]
        end
      end
    end
  end
end
