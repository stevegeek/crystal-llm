# ported from lib/ruby_llm/providers/xai/models.rb @ ruby_llm 1.16.0
#
# xAI list-models parsing + the per-model capability/modality classification.
#
# Divergences:
# - ruby_llm splits this into a `Models` module mixed into the XAI class; the Crystal
#   port reopens Providers::XAI and adds the same methods directly.
# - response.body is a raw String (Crest); JSON.parse it here (ruby_llm's Faraday
#   middleware pre-parses).
# - Time.at(created) -> Time.unix(created).
# - The `capabilities` argument (the OpenAI Capabilities class passed by the
#   completion pipeline) is intentionally unused — xAI classifies capabilities from
#   its own image/video id-pattern predicates, exactly as ruby_llm's `_capabilities`
#   parameter is unused. See xai.cr header.
# - format_display_name: `model_id.tr('-', ' ').split.map(&:capitalize).join(' ')`
#   -> split on '-', capitalize each word, join with space.
#
# ruby_llm 3f27b864 (Integrate models.dev metadata and provider cleanup): the
# hard-coded IMAGE_MODELS/VISION_MODELS/REASONING_MODELS id lists are GONE —
# vision/reasoning/function_calling/structured_output for chat models now come
# from models.dev (xai joined MODELS_DEV_PROVIDER_MAP in models.cr). This live
# list_models parse only self-classifies image/video-*generation* models by id
# pattern (`image_model?`/`video_model?`); every other model gets a bare
# `["streaming"]` fallback capability.
require "json"
require "../openai"

module CrystalLLM
  module Providers
    class XAI < OpenAI
      def models_url : String
        "models"
      end

      def parse_list_models_response(response : Crest::Response, slug : String,
                                     capabilities : CrystalLLM::Capabilities.class) : Array(Model::Info)
        body = response.body
        return [] of Model::Info if body.empty?

        data = JSON.parse(body)
        rows = data["data"]?.try(&.as_a?) || [] of JSON::Any

        rows.compact_map do |row_any|
          row = row_any.as_h? || next
          model_id = row["id"]?.try(&.as_s?) || next

          created_at = nil
          if created = row["created"]?
            if epoch = created.as_i64?
              created_at = Time.unix(epoch)
            end
          end

          metadata = {} of String => JSON::Any
          if object = row["object"]?
            metadata["object"] = object unless object.raw.nil?
          end
          if owned_by = row["owned_by"]?
            metadata["owned_by"] = owned_by unless owned_by.raw.nil?
          end

          Model::Info.build(
            id: model_id,
            name: format_display_name(model_id),
            provider: slug,
            family: "grok",
            created_at: created_at,
            context_window: nil,
            max_output_tokens: nil,
            modalities: modalities_for(model_id),
            capabilities: capabilities_for(model_id),
            pricing: Model::Pricing.new,
            metadata: metadata
          )
        end
      end

      def modalities_for(model_id : String) : Model::Modalities
        if image_model?(model_id)
          Model::Modalities.new(input: %w[text image], output: ["image"])
        elsif video_model?(model_id)
          Model::Modalities.new(input: %w[text image video], output: ["video"])
        else
          Model::Modalities.new(input: ["text"], output: ["text"])
        end
      end

      def capabilities_for(model_id : String) : Array(String)
        return ["vision"] if image_model?(model_id) || video_model?(model_id)

        ["streaming"]
      end

      def format_display_name(model_id : String) : String
        model_id.split('-').map(&.capitalize).join(' ')
      end

      # ruby_llm: `model_id.match?(/\Agrok-(?:2-)?imagine-image/) || model_id == 'grok-2-image-1212'`.
      def image_model?(model_id : String) : Bool
        !!model_id.match(/\Agrok-(?:2-)?imagine-image/) || model_id == "grok-2-image-1212"
      end

      # ruby_llm: `model_id.match?(/\Agrok-(?:2-)?imagine-video/)`.
      def video_model?(model_id : String) : Bool
        !!model_id.match(/\Agrok-(?:2-)?imagine-video/)
      end
    end
  end
end
