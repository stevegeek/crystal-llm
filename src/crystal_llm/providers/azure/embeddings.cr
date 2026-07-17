# ported from lib/ruby_llm/providers/azure/embeddings.rb @ ruby_llm 1.16.0
#
# Azure AI Foundry embeddings hooks, reopening Providers::Azure. ruby_llm mixes
# these in via the `Azure::Embeddings` `module_function` module; the Crystal port
# reopens the class (matching how azure/{chat,models}.cr and openai/embeddings.cr
# are organized).
#
# Azure overrides only `embedding_url` and `render_embedding_payload`.
# `parse_embedding_response` is INHERITED from OpenAI (ruby_llm's Azure mixes in
# OpenAI's behavior and only redefines these two). We `require "../openai/embeddings"`
# so that the inherited `parse_embedding_response` (which carries the flatten-single
# -vector rule) is loaded onto the OpenAI superclass and thus available on Azure.
#
# == Divergences from ruby_llm + from the OpenAI port ==
#
# * `embedding_url` -> `azure_endpoint("embeddings")` (ruby_llm: `azure_endpoint(:embeddings)`;
#   symbol -> String per design §11). The endpoint builder lives in azure.cr.
#
# * `render_embedding_payload` differs from OpenAI's: Azure ALWAYS sends `input` as
#   an array (ruby_llm: `[text].flatten`) — a single String becomes a 1-element array.
#   OpenAI passes `text` through verbatim (a String stays a String on the wire).
#   `dimensions` is included only when non-nil (ruby_llm's `.compact` drops a nil key;
#   the port simply skips the key — same wire result). `text`/`dimensions` are typed
#   per the Provider hook signatures (Provider::TextInput / Int32?).
#
# * `parse_embedding_response`'s flatten-single-vector rule keys off the ORIGINAL
#   `text` argument (`!text.is_a?(Array)`), NOT the rendered always-array payload — so
#   a single-String input still yields a flat vector. This matches ruby_llm exactly
#   (Azure inherits OpenAI's parse, which inspects `text`, not the payload).
#
# * `response.body` is a raw JSON String (Crest); the inherited parse JSON.parses it
#   (ruby_llm's Faraday json middleware pre-parses). Same as the OpenAI port.
require "json"
require "../azure"
require "../openai/embeddings"
require "../../provider_media"
require "../../embedding"

module CrystalLLM
  module Providers
    class Azure < OpenAI
      def embedding_url(model : String) : String
        azure_endpoint("embeddings")
      end

      def render_embedding_payload(text : Provider::TextInput, model : String,
                                   dimensions : Int32?) : Hash(String, JSON::Any)
        payload = {
          "model" => JSON::Any.new(model),
          "input" => text_to_array_json(text),
        } of String => JSON::Any
        # ruby_llm's `.compact` drops a nil dimensions; the port just skips the key.
        payload["dimensions"] = JSON::Any.new(dimensions.to_i64) unless dimensions.nil?
        payload
      end

      # Azure always sends `input` as an array (ruby_llm: `[text].flatten`):
      # a single String becomes a 1-element array; a batch passes through.
      private def text_to_array_json(text : Provider::TextInput) : JSON::Any
        case text
        when String
          JSON::Any.new([JSON::Any.new(text)])
        else
          JSON::Any.new(text.map { |item| JSON::Any.new(item) })
        end
      end
    end
  end
end
