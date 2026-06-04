# ported from lib/ruby_llm/providers/vertexai/models.rb @ ruby_llm 1.15.0
#
# Divergences:
# - ruby_llm's `list_models` does its own paginated `@connection.get` loop (custom
#   headers/params, page tokens) and concatenates KNOWN_GOOGLE_MODELS. The frozen
#   CrystalLLM pipeline calls `models_url` + `parse_list_models_response(response,
#   slug, capabilities)`; the port maps to that single-page hook. `parse_list_models_response`
#   parses the `publisherModels` array (skipping DEPRECATED) and PREPENDS the known
#   models, mirroring ruby_llm's `all_models.concat(build_known_models)` then API rows.
#   Pagination (nextPageToken) is not threaded by the frozen single-call hook — a
#   documented divergence (one page is parsed).
# - `response.body` is a raw String (Crest); JSON.parse it here.
require "json"
require "../vertexai"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      # Gemini / Google models not always returned by the API (ruby_llm parity).
      KNOWN_GOOGLE_MODELS = %w[
        gemini-2.5-flash-lite
        gemini-2.5-pro
        gemini-2.5-flash
        gemini-2.0-flash-lite-001
        gemini-2.0-flash-001
        gemini-2.0-flash
        gemini-2.0-flash-exp
        gemini-1.5-pro-002
        gemini-1.5-pro
        gemini-1.5-flash-002
        gemini-1.5-flash
        gemini-1.5-flash-8b
        gemini-pro
        gemini-pro-vision
        gemini-exp-1206
        gemini-exp-1121
        gemini-embedding-001
        text-embedding-005
        text-embedding-004
        text-multilingual-embedding-002
      ]

      def models_url : String
        "publishers/google/models"
      end

      def parse_list_models_response(response : Crest::Response, slug : String,
                                     capabilities : CrystalLLM::Capabilities.class) : Array(Model::Info)
        models = build_known_models(slug)

        body = response.body
        return models if body.empty?

        data = JSON.parse(body)
        rows = data["publisherModels"]?.try(&.as_a?) || [] of JSON::Any

        rows.each do |row_any|
          row = row_any.as_h? || next
          next if row["launchStage"]?.try(&.as_s?) == "DEPRECATED"

          model_id = extract_model_id_from_path(row["name"]?.try(&.as_s?))
          next if model_id.empty?

          models << build_model_from_api_data(row, model_id, slug)
        end

        models
      rescue JSON::ParseException
        build_known_models(slug)
      end

      private def build_known_models(slug : String) : Array(Model::Info)
        KNOWN_GOOGLE_MODELS.map do |model_id|
          Model::Info.build(
            id: model_id,
            name: model_id,
            provider: slug,
            family: determine_model_family(model_id),
            capabilities: %w[streaming function_calling],
            metadata: {"source" => JSON::Any.new("known_models")}
          )
        end
      end

      private def build_model_from_api_data(row : Hash(String, JSON::Any), model_id : String,
                                            slug : String) : Model::Info
        metadata = {
          "version_id"               => row["versionId"]? || JSON::Any.new(nil),
          "open_source_category"     => row["openSourceCategory"]? || JSON::Any.new(nil),
          "launch_stage"             => row["launchStage"]? || JSON::Any.new(nil),
          "supported_actions"        => row["supportedActions"]? || JSON::Any.new(nil),
          "publisher_model_template" => row["publisherModelTemplate"]? || JSON::Any.new(nil),
        } of String => JSON::Any

        Model::Info.build(
          id: model_id,
          name: model_id,
          provider: slug,
          family: determine_model_family(model_id),
          capabilities: extract_capabilities(row),
          metadata: metadata
        )
      end

      private def extract_model_id_from_path(path : String?) : String
        return "" if path.nil?
        path.split("/").last
      end

      private def determine_model_family(model_id : String) : String
        case model_id
        when .matches?(/^gemini-2\.\d+/)  then "gemini-2"
        when .matches?(/^gemini-1\.\d+/)  then "gemini-1.5"
        when .matches?(/^text-embedding/) then "text-embedding"
        when .matches?(/bison/)           then "palm"
        else                                   "gemini"
        end
      end

      private def extract_capabilities(row : Hash(String, JSON::Any)) : Array(String)
        capabilities = ["streaming"]
        model_name = row["name"]?.try(&.as_s?) || ""
        capabilities << "function_calling" if model_name.includes?("gemini")
        capabilities.uniq
      end
    end
  end
end
