# ported from lib/ruby_llm/providers/gemini/models.rb @ ruby_llm 1.15.0
#
# Divergences:
# - `response.body` is a raw String (Crest); JSON.parse it here.
# - Model ids are `models/<id>` on the wire; the `models/` prefix is stripped.
# - Capabilities is a class (provider_completion.cr); the helper class is passed in.
# - Model::Info is built via `.build`; pricing arrives as a `Hash(String, JSON::Any)`
#   and is wrapped in Model::Pricing.
require "json"
require "../gemini"

module CrystalLLM
  module Providers
    class Gemini < Provider
      def models_url : String
        "models"
      end

      # ameba:disable Metrics/CyclomaticComplexity
      def parse_list_models_response(response : Crest::Response, slug : String,
                                     capabilities : CrystalLLM::Capabilities.class) : Array(Model::Info)
        body = response.body
        return [] of Model::Info if body.empty?

        data = JSON.parse(body)
        rows = data["models"]?.try(&.as_a?) || [] of JSON::Any

        rows.compact_map do |row_any|
          row = row_any.as_h? || next
          raw_name = row["name"]?.try(&.as_s?) || next
          model_id = raw_name.gsub("models/", "")

          context_window = int_or_nil(row["inputTokenLimit"]?) || capabilities.context_window_for(model_id)
          max_output = int_or_nil(row["outputTokenLimit"]?) || capabilities.max_tokens_for(model_id)

          metadata = {
            "version"                      => row["version"]? || JSON::Any.new(nil),
            "description"                  => row["description"]? || JSON::Any.new(nil),
            "supported_generation_methods" => row["supportedGenerationMethods"]? || JSON::Any.new(nil),
          } of String => JSON::Any

          Model::Info.build(
            id: model_id,
            name: row["displayName"]?.try(&.as_s?) || model_id,
            provider: slug,
            created_at: nil,
            context_window: context_window,
            max_output_tokens: max_output,
            capabilities: capabilities.critical_capabilities_for(model_id),
            pricing: Model::Pricing.new(capabilities.pricing_for(model_id)),
            metadata: metadata
          )
        end
      end

      private def int_or_nil(value : JSON::Any?) : Int32?
        return nil if value.nil?
        case raw = value.raw
        when Int64   then raw.to_i32
        when Int32   then raw
        when Float64 then raw.to_i32
        else              nil
        end
      end
    end
  end
end
