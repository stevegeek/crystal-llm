# ported from lib/ruby_llm/providers/vertexai/embeddings.rb @ ruby_llm 1.16.0
#
# Vertex AI embeddings hooks (embedding_url / render_embedding_payload /
# parse_embedding_response), reopening Providers::VertexAI. ruby_llm mixes these in
# via the `VertexAI::Embeddings` `module_function` module; the Crystal port reopens
# the class (matching how chat.cr / streaming.cr / etc. are organized here).
#
# Vertex's predict endpoint differs from Gemini's batchEmbedContents: the request is
# `{ instances: [{ content: <text> }, ...] }` (optionally with
# `{ parameters: { outputDimensionality: <dims> } }`), and the response is
# `{ predictions: [{ embeddings: { values: [...] } }, ...] }`.
#
# Divergences (match openai/embeddings.cr's structural template):
# - `response.body` is a raw JSON String (Crest); parse JSON.parses it (ruby_llm's
#   Faraday json middleware pre-parses). Matches parse_completion_response (chat.cr).
# - `text` is `Provider::TextInput` (String | Array(String)) — design §11.
# - The "flatten single vector" rule mirrors ruby_llm exactly: when there is exactly
#   one returned vector AND the input was not an Array, return the flat vector;
#   otherwise return the batch. Typed against `Embedding::Vectors`.
# - ruby_llm's `input_tokens: 0` is preserved verbatim (Vertex's predict response
#   carries no usable token count here, so the port hardcodes 0 like ruby_llm).
require "json"
require "../vertexai"
require "../../provider_media"
require "../../embedding"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      def embedding_url(model : String) : String
        "projects/#{@config.vertexai_project_id}/locations/#{@config.vertexai_location}/" \
        "publishers/google/models/#{model}:predict"
      end

      # `{ instances: [{ content: t }, ...] }`, plus `parameters.outputDimensionality`
      # when dimensions is given. (ruby_llm: `[text].flatten.map { |t| { content: t.to_s } }`.)
      def render_embedding_payload(text : Provider::TextInput, model : String,
                                   dimensions : Int32?) : Hash(String, JSON::Any)
        instances = text_items(text).map do |item|
          JSON::Any.new({"content" => JSON::Any.new(item)} of String => JSON::Any)
        end

        payload = {
          "instances" => JSON::Any.new(instances),
        } of String => JSON::Any

        unless dimensions.nil?
          payload["parameters"] = JSON::Any.new(
            {"outputDimensionality" => JSON::Any.new(dimensions.to_i64)} of String => JSON::Any
          )
        end

        payload
      end

      def parse_embedding_response(response : Crest::Response, model : String,
                                   text : Provider::TextInput) : Embedding
        data = JSON.parse(response.body)

        predictions = data["predictions"]?.try(&.as_a?) || [] of JSON::Any
        nested = predictions.map { |prediction| extract_vector(prediction) }

        vectors : Embedding::Vectors = if nested.size == 1 && !text.is_a?(Array)
          nested.first
        else
          nested
        end

        Embedding.new(vectors: vectors, model: model, input_tokens: 0)
      end

      # Normalizes embed input to an Array(String): a single string -> one-element
      # array, a batch -> itself (ruby_llm's `[text].flatten`).
      private def text_items(text : Provider::TextInput) : Array(String)
        case text
        when String
          [text]
        else
          text
        end
      end

      # Pulls one prediction's `embeddings.values` array into Array(Float64).
      # (ruby_llm: `p.dig('embeddings', 'values')`.)
      private def extract_vector(prediction : JSON::Any) : Array(Float64)
        arr = prediction.dig?("embeddings", "values").try(&.as_a?) || [] of JSON::Any
        arr.map { |v| (v.as_f? || v.as_i?.try(&.to_f) || 0.0).as(Float64) }
      end
    end
  end
end
