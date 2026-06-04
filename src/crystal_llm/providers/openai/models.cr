# ported from lib/ruby_llm/providers/openai/models.rb @ ruby_llm 1.15.0
#
# Divergences:
# - `response.body` is a raw String (Crest); JSON.parse it here.
# - `Time.at(created)` -> `Time.unix(created)`.
# - Capabilities is a class (provider_completion.cr); the helper class is passed in.
# - Model::Info is built via `.build` (the keyword native-value constructor); pricing
#   arrives as a `Hash(String, JSON::Any)` and is wrapped in Pricing.
require "json"
require "../openai"

module CrystalLLM
  module Providers
    class OpenAI < Provider
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

          metadata = {
            "object"   => row["object"]? || JSON::Any.new(nil),
            "owned_by" => row["owned_by"]? || JSON::Any.new(nil),
          } of String => JSON::Any

          Model::Info.build(
            id: model_id,
            name: model_id,
            provider: slug,
            created_at: created_at,
            context_window: capabilities.context_window_for(model_id),
            max_output_tokens: capabilities.max_tokens_for(model_id),
            capabilities: capabilities.critical_capabilities_for(model_id),
            pricing: Model::Pricing.new(capabilities.pricing_for(model_id)),
            metadata: metadata
          )
        end
      end
    end
  end
end
