# ported from lib/ruby_llm/providers/ollama/embeddings.rb @ ruby_llm 1.15.0
#
# Ollama embeddings hooks (embedding_url / render_embedding_payload /
# parse_embedding_response), reopening Providers::Ollama.
#
# UPSTREAM NOTE: ruby_llm has NO `lib/ruby_llm/providers/ollama/embeddings.rb`.
# Ollama exposes an OpenAI-compatible `/v1/embeddings` endpoint, so ruby_llm's
# `Ollama < OpenAI` inherits the OpenAI `Embeddings` module verbatim
# (`embedding_url` => "embeddings", `render_embedding_payload` => model/input/
# dimensions, `parse_embedding_response` => map `data[].embedding`, flatten the
# single-vector case). The Crystal port keeps the same inheritance — `Ollama <
# OpenAI` already picks up providers/openai/embeddings.cr — but spells the three
# hooks out here so the ollama media surface is self-contained, explicitly
# documented, and directly fixture-testable, while delegating the actual shape to
# the OpenAI implementation via `super`. This is the "matching" port: the ollama
# payload/parse shapes ARE the OpenAI shapes (that is what ollama's OpenAI-compat
# embeddings endpoint speaks).
#
# Divergences (all inherited from providers/openai/embeddings.cr):
# - `response.body` is a raw JSON String (Crest); the OpenAI parse JSON.parses it.
# - `text` is `Provider::TextInput` (String | Array(String)) — design §11.
# - The "flatten single vector" rule mirrors ruby_llm exactly (flat only when one
#   returned vector AND the input was not an Array).
require "json"
require "../ollama"
require "../openai/embeddings"
require "../../provider_media"
require "../../embedding"

module CrystalLLM
  module Providers
    class Ollama < OpenAI
      # ollama (OpenAI-compatible): POST /v1/embeddings. Same path token as OpenAI.
      def embedding_url(model : String) : String
        super
      end

      # Same payload shape as OpenAI: {model, input[, dimensions]}.
      def render_embedding_payload(text : Provider::TextInput, model : String,
                                   dimensions : Int32?) : Hash(String, JSON::Any)
        super
      end

      # Same response shape as OpenAI: data[].embedding (+ usage.prompt_tokens),
      # with the single-vector flatten rule.
      def parse_embedding_response(response : Crest::Response, model : String,
                                   text : Provider::TextInput) : Embedding
        super
      end
    end
  end
end
