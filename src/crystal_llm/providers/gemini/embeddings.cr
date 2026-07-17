# ported from lib/ruby_llm/providers/gemini/embeddings.rb @ ruby_llm 1.16.0
#
# Gemini embeddings hooks (embedding_url / render_embedding_payload /
# parse_embedding_response), reopening Providers::Gemini. Gemini's batch-embed
# endpoint (`models/<model>:batchEmbedContents`) takes a `requests` array, one
# `single_embedding_payload` per input text, and returns an `embeddings` array
# whose entries each carry a `values` vector.
#
# Structural template: providers/openai/embeddings.cr. The payload/parse SHAPES
# follow gemini/embeddings.rb (NOT the OpenAI wire shape).
#
# Divergences from ruby_llm:
# - `response.body` is a raw JSON String (Crest); parse JSON.parses it (ruby_llm's
#   Faraday json middleware pre-parses). Matches parse_completion_response.
# - `text` is `Provider::TextInput` (String | Array(String)) — design §11. ruby_llm's
#   `[text].flatten` (wrap-then-flatten a String-or-Array) becomes an explicit
#   `each_input` that yields the single string or each array element.
# - The "flatten single vector" rule mirrors ruby_llm exactly: when there is exactly
#   one returned vector AND the input was not an Array, return the flat vector;
#   otherwise return the batch. Result typed against `Embedding::Vectors`.
# - ruby_llm's `single_embedding_payload` uses `.compact` to drop a nil
#   `outputDimensionality`; the port just skips the key when dimensions is nil.
# - input_tokens is hard-coded 0 (ruby_llm: `input_tokens: 0` — Gemini's batch-embed
#   response carries no token usage).
require "json"
require "../gemini"
require "../../provider_media"
require "../../embedding"

module CrystalLLM
  module Providers
    class Gemini < Provider
      def embedding_url(model : String) : String
        "models/#{model}:batchEmbedContents"
      end

      def render_embedding_payload(text : Provider::TextInput, model : String,
                                   dimensions : Int32?) : Hash(String, JSON::Any)
        requests = [] of JSON::Any
        each_input(text) do |input|
          requests << single_embedding_payload(input, model: model, dimensions: dimensions)
        end
        {"requests" => JSON::Any.new(requests)} of String => JSON::Any
      end

      def parse_embedding_response(response : Crest::Response, model : String,
                                   text : Provider::TextInput) : Embedding
        data = JSON.parse(response.body)

        rows = data["embeddings"]?.try(&.as_a?) || [] of JSON::Any
        nested = rows.map { |row| extract_values(row) }

        vectors : Embedding::Vectors = if nested.size == 1 && !text.is_a?(Array)
          nested.first
        else
          nested
        end

        Embedding.new(vectors: vectors, model: model, input_tokens: 0)
      end

      # One `{model, content: {parts: [{text}]}, outputDimensionality?}` request.
      private def single_embedding_payload(text : String, model : String,
                                           dimensions : Int32?) : JSON::Any
        parts = [JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any)]
        obj = {
          "model"   => JSON::Any.new("models/#{model}"),
          "content" => JSON::Any.new({"parts" => JSON::Any.new(parts)} of String => JSON::Any),
        } of String => JSON::Any
        obj["outputDimensionality"] = JSON::Any.new(dimensions.to_i64) unless dimensions.nil?
        JSON::Any.new(obj)
      end

      # Yields the single string, or each element of an array input (ruby_llm's
      # `[text].flatten` over a String-or-Array).
      private def each_input(text : Provider::TextInput, &)
        case text
        when String
          yield text
        else
          text.each { |item| yield item }
        end
      end

      # Pulls one embedding row's `values` array into Array(Float64).
      private def extract_values(row : JSON::Any) : Array(Float64)
        arr = row["values"]?.try(&.as_a?) || [] of JSON::Any
        arr.map { |v| (v.as_f? || v.as_i?.try(&.to_f) || 0.0).as(Float64) }
      end
    end
  end
end
