# ported from lib/ruby_llm/providers/anthropic/models.rb @ ruby_llm 1.16.0
#
# Divergences:
# - `response.body` is a raw String (Crest); JSON.parse it here.
# - `Time.parse(model_data['created_at'])` -> Crystal `Time.parse_iso8601` (Anthropic
#   returns RFC3339/ISO8601 timestamps); a parse failure leaves created_at nil rather
#   than raising.
# - Capabilities is a class (provider_completion.cr); the helper class is passed in.
# - Model::Info is built via `.build` (the keyword native-value constructor).
require "json"
require "../anthropic"

module CrystalLLM
  module Providers
    class Anthropic < Provider
      def models_url : String
        "v1/models"
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

          name = row["display_name"]?.try(&.as_s?) || model_id

          created_at = nil
          if created = row["created_at"]?.try(&.as_s?)
            created_at = parse_time(created)
          end

          Model::Info.build(
            id: model_id,
            name: name,
            provider: slug,
            created_at: created_at,
            metadata: {} of String => JSON::Any
          )
        end
      end

      private def parse_time(value : String) : Time?
        Time.parse_iso8601(value)
      rescue Time::Format::Error
        nil
      end
    end
  end
end
