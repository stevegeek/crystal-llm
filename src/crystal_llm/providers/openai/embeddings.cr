# ported from lib/ruby_llm/providers/openai/embeddings.rb @ ruby_llm 1.15.0
#
# OpenAI embeddings hooks (render_embedding_payload / parse_embedding_response /
# embedding_url), reopening Providers::OpenAI. ruby_llm mixes these in via the
# `OpenAI::Embeddings` `module_function` module; the Crystal port reopens the
# class (matching how chat.cr/streaming.cr/etc. are organized).
#
# Divergences:
# - `response.body` is a raw JSON String (Crest); parse JSON.parses it (ruby_llm's
#   Faraday json middleware pre-parses). Matches parse_completion_response (chat.cr).
# - `text` is `Provider::TextInput` (String | Array(String)) — design §11.
# - The "flatten single vector" rule mirrors ruby_llm exactly: when there is exactly
#   one returned vector AND the input was not an Array, return the flat vector;
#   otherwise return the batch (Array(Array(Float64))). The result is typed against
#   `Embedding::Vectors` (the port's flat-or-nested union).
require "json"
require "../openai"
require "../../provider_media"
require "../../embedding"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      def embedding_url(model : String) : String
        "embeddings"
      end

      def render_embedding_payload(text : Provider::TextInput, model : String,
                                   dimensions : Int32?) : Hash(String, JSON::Any)
        payload = {
          "model" => JSON::Any.new(model),
          "input" => text_to_json(text),
        } of String => JSON::Any
        # ruby_llm uses `.compact` to drop a nil dimensions; here we just skip it.
        payload["dimensions"] = JSON::Any.new(dimensions.to_i64) unless dimensions.nil?
        payload
      end

      def parse_embedding_response(response : Crest::Response, model : String,
                                   text : Provider::TextInput) : Embedding
        data = JSON.parse(response.body)

        input_tokens = data.dig?("usage", "prompt_tokens").try(&.as_i?) || 0

        rows = data["data"]?.try(&.as_a?) || [] of JSON::Any
        nested = rows.map { |row| extract_vector(row) }

        vectors : Embedding::Vectors = if nested.size == 1 && !text.is_a?(Array)
          nested.first
        else
          nested
        end

        Embedding.new(vectors: vectors, model: model, input_tokens: input_tokens)
      end

      # Wraps embed input for the wire: a single string or a batch of strings.
      private def text_to_json(text : Provider::TextInput) : JSON::Any
        case text
        when String
          JSON::Any.new(text)
        else
          JSON::Any.new(text.map { |item| JSON::Any.new(item) })
        end
      end

      # Pulls one embedding row's `embedding` array into Array(Float64).
      private def extract_vector(row : JSON::Any) : Array(Float64)
        arr = row["embedding"]?.try(&.as_a?) || [] of JSON::Any
        arr.map { |v| (v.as_f? || v.as_i?.try(&.to_f) || 0.0).as(Float64) }
      end
    end
  end
end
