# ported from lib/ruby_llm/providers/ollama/models.rb @ ruby_llm 1.16.0
#
# Divergences:
# - `response.body` is a raw String (Crest); JSON.parse it here (ruby_llm's Faraday
#   json middleware pre-parses).
# - `Time.at(created)` -> `Time.unix(created)`.
# - `models_url` is "models" (same as OpenAI's), so it is inherited and not redefined.
# - ruby_llm's `Model::Info.new(...)` keyword constructor maps to the `.build`
#   native-value constructor; the fixed modalities/capabilities/metadata are passed
#   as typed values (Modalities, Array(String), Hash(String, JSON::Any)).
require "json"
require "../ollama"

module CrystalLLM
  module Providers
    class Ollama < OpenAI
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
            "owned_by" => row["owned_by"]? || JSON::Any.new(nil),
          } of String => JSON::Any

          Model::Info.build(
            id: model_id,
            name: model_id,
            provider: slug,
            family: "ollama",
            created_at: created_at,
            modalities: Model::Modalities.new(input: %w[text image], output: %w[text]),
            capabilities: %w[streaming function_calling structured_output vision],
            pricing: Model::Pricing.new,
            metadata: metadata
          )
        end
      end
    end
  end
end
