# ported from lib/ruby_llm/embedding.rb @ ruby_llm 1.16.0
module CrystalLLM
  # Core embedding interface — a data holder for an embedding response.
  #
  # `vectors` is shape-polymorphic (design N3): a single-text embed yields a flat
  # `Array(Float64)`, a batch embed yields `Array(Array(Float64))`. Ruby duck-types
  # on `vectors.first.is_a?(Array)`; Crystal needs the union spelled out, so
  # `Vectors` is `Array(Float64) | Array(Array(Float64))`. The shape helpers
  # (`vector_dimensions` / `embedding_count`) branch on the concrete runtime type.
  class Embedding
    # The polymorphic vector payload: flat for single input, nested for a batch.
    alias Vectors = Array(Float64) | Array(Array(Float64))

    getter vectors : Vectors
    getter model : String
    getter input_tokens : Int32

    def initialize(@vectors : Vectors, @model : String, @input_tokens : Int32 = 0)
    end

    # `Embedding.embed(text, model:, provider:, ...)` (ruby_llm's class method)
    # lives in `provider_media.cr` (it resolves a model + Provider instance and
    # runs the embed pipeline). The data class + shape helpers below are complete.

    # Number of dimensions per vector. For a batch, inspects the first row.
    # Mirrors ruby_llm's `Embedding.vector_dimensions`.
    def self.vector_dimensions(vectors : Vectors) : Int32
      case vectors
      when Array(Array(Float64))
        first = vectors.first?
        first ? first.size : 0
      else
        vectors.size
      end
    end

    # Number of embeddings: 1 for a single flat vector, the batch size otherwise.
    # Mirrors ruby_llm's `Embedding.embedding_count`.
    def self.embedding_count(vectors : Vectors) : Int32
      case vectors
      when Array(Array(Float64))
        vectors.size
      else
        1
      end
    end
  end
end
