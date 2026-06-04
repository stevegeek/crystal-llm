# ported from lib/ruby_llm/providers/mistral/embeddings.rb @ ruby_llm 1.15.0
#
# Mistral embeddings hooks (embedding_url / render_embedding_payload /
# parse_embedding_response), reopening Providers::Mistral. ruby_llm mixes these in
# via the `Mistral::Embeddings` `module_function` module; the Crystal port reopens
# the class (matching how mistral/chat.cr / mistral/models.cr are organized, and
# the OpenAI embeddings port in providers/openai/embeddings.cr).
#
# Mistral is OpenAI-compatible at the chat layer (Mistral < OpenAI), but its
# embeddings surface diverges from OpenAI's in one way, so this does NOT just
# inherit the OpenAI hooks:
#
#   render_embedding_payload — Mistral does NOT send `dimensions`. ruby_llm's
#   method takes a `dimensions:` keyword (to satisfy the shared `Provider#embed`
#   call site) but ignores it (`rubocop:disable Lint/UnusedMethodArgument`); the
#   payload is just `{model:, input: text}`. The OpenAI port appends a
#   `"dimensions"` key when non-nil — Mistral must not. So we override here rather
#   than inherit OpenAI's render (which would leak a `dimensions` key Mistral's
#   API doesn't accept).
#
# `parse_embedding_response` is structurally identical to OpenAI's (same
# `data[].embedding` rows + `usage.prompt_tokens`, same flatten-single rule), so it
# could be inherited — but ruby_llm's Mistral module redefines it verbatim, and the
# port mirrors the upstream file 1:1. Reproduced here (matching the upstream layout)
# rather than relying on the inherited OpenAI impl.
#
# == Divergences from ruby_llm's mistral/embeddings.rb (documented + returned) ==
#
# * `response.body` is a raw JSON String (Crest); parse JSON.parses it (ruby_llm's
#   Faraday json middleware pre-parses). Matches parse_completion_response and the
#   OpenAI embeddings port.
# * Symbols-as-runtime-data → String (design §11): `text` is `Provider::TextInput`
#   (String | Array(String)); `model` is a resolved String id.
# * The "flatten single vector" rule mirrors ruby_llm exactly: when there is exactly
#   one returned vector AND the input was not an Array, return the flat vector;
#   otherwise return the batch. Typed against `Embedding::Vectors` (flat-or-nested
#   union — see embedding.cr).
# * `dimensions` is accepted (to satisfy the `Provider#embed` hook signature) but —
#   faithful to ruby_llm — intentionally unused in the payload (Mistral's embeddings
#   API has no dimensions parameter). Documented as a no-op, not an omission.
require "json"
require "../mistral"
require "../../provider_media"
require "../../embedding"

module CrystalLLM
  module Providers
    class Mistral < OpenAI
      def embedding_url(model : String) : String
        "embeddings"
      end

      # NOTE: `dimensions` is intentionally unused — Mistral's embeddings API has no
      # dimensions parameter (faithful to ruby_llm, which carries the keyword only to
      # satisfy the shared Provider#embed call site). Do NOT inherit OpenAI's render
      # (it appends a "dimensions" key Mistral rejects).
      def render_embedding_payload(text : Provider::TextInput, model : String,
                                   dimensions : Int32?) : Hash(String, JSON::Any)
        {
          "model" => JSON::Any.new(model),
          "input" => text_to_json(text),
        } of String => JSON::Any
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
      # (Mirrors the OpenAI port's helper; kept private + local so this file is
      # self-contained and does not depend on OpenAI's private method visibility.)
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
