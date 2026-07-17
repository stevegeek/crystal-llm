# ported from lib/ruby_llm/providers/mistral/models.rb @ ruby_llm 1.16.0
#
# Mistral's list-models endpoint shares OpenAI's `models` path but maps each row
# through the richer Mistral capabilities helper (display name / family / modalities
# / created_at from `release_date_for`).
#
# Divergences:
# - `response.body` is a raw String (Crest); JSON.parse it here.
# - The `capabilities` argument is typed `CrystalLLM::Capabilities.class`; it is
#   downcast to the Mistral helper to reach the Mistral-specific class methods
#   (display name, family, modalities, release_date). This is safe because the
#   completion pipeline passes `self.class.capabilities`, which for Mistral is
#   `Mistral::Capabilities`.
# - `Time.parse(release_date)` -> Model::Info.to_time on the release-date string.
require "json"
require "../mistral"

module CrystalLLM
  module Providers
    class Mistral < OpenAI
      def parse_list_models_response(response : Crest::Response, slug : String,
                                     capabilities : CrystalLLM::Capabilities.class) : Array(Model::Info)
        body = response.body
        return [] of Model::Info if body.empty?

        caps = capabilities.is_a?(Mistral::Capabilities.class) ? capabilities : Mistral::Capabilities

        data = JSON.parse(body)
        rows = data["data"]?.try(&.as_a?) || [] of JSON::Any

        rows.compact_map do |row_any|
          row = row_any.as_h? || next
          model_id = row["id"]?.try(&.as_s?) || next

          created_at = nil
          if release_date = caps.release_date_for(model_id)
            created_at = Model::Info.to_time(JSON::Any.new(release_date))
          end

          metadata = {
            "object"   => row["object"]? || JSON::Any.new(nil),
            "owned_by" => row["owned_by"]? || JSON::Any.new(nil),
          } of String => JSON::Any

          Model::Info.build(
            id: model_id,
            name: caps.format_display_name(model_id),
            provider: slug,
            family: caps.model_family(model_id),
            created_at: created_at,
            context_window: caps.context_window_for(model_id),
            max_output_tokens: caps.max_tokens_for(model_id),
            modalities: Model::Modalities.new(caps.modalities_for(model_id)),
            capabilities: caps.capabilities_for(model_id),
            pricing: Model::Pricing.new(caps.pricing_for(model_id)),
            metadata: metadata
          )
        end
      end
    end
  end
end
