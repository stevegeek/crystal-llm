# ported from lib/ruby_llm/providers/anthropic/embeddings.rb @ ruby_llm 1.15.0
#
# Anthropic does not support embeddings. This module overrides the three embedding
# provider hooks to raise a clear error, completing surface parity with ruby_llm's
# stub (which aliases all three to a single `embed` method that raises).
#
# Divergences from ruby_llm:
# - Ruby uses `alias` to point all three methods at the same raise. Crystal has no
#   method aliases, so each override is written out individually — same behavior.
# - The error class is `CrystalLLM::Error` (not `RubyLLM::Error`).
require "json"
require "../anthropic"

module CrystalLLM
  module Providers
    class Anthropic < Provider
      # Embeddings methods — Anthropic does not support embeddings.
      module Embeddings
        # Raises: Anthropic doesn't support embeddings.
        def embedding_url(model : String) : String
          raise CrystalLLM::Error.new("Anthropic doesn't support embeddings")
        end

        # Raises: Anthropic doesn't support embeddings.
        def render_embedding_payload(text : TextInput, model : String,
                                     dimensions : Int32?) : Hash(String, JSON::Any)
          raise CrystalLLM::Error.new("Anthropic doesn't support embeddings")
        end

        # Raises: Anthropic doesn't support embeddings.
        def parse_embedding_response(response : Crest::Response, model : String,
                                     text : TextInput) : Embedding
          raise CrystalLLM::Error.new("Anthropic doesn't support embeddings")
        end
      end

      include Embeddings
    end
  end
end
