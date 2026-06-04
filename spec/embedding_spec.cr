require "./spec_helper"
require "../src/crystal_llm/embedding"

# Focused unit spec for the Embedding DATA class. The upstream spec
# (spec/ruby_llm/embeddings_spec.rb) is VCR/integration and is intentionally
# not ported; this covers the data holder + shape-polymorphic `vectors` (N3).
describe CrystalLLM::Embedding do
  describe "single (flat) vector" do
    it "stores vectors, model, and input_tokens" do
      emb = CrystalLLM::Embedding.new(
        vectors: [0.1, 0.2, 0.3],
        model: "text-embedding-3-small",
        input_tokens: 5
      )
      emb.vectors.should eq([0.1, 0.2, 0.3])
      emb.model.should eq("text-embedding-3-small")
      emb.input_tokens.should eq(5)
    end

    it "defaults input_tokens to 0" do
      emb = CrystalLLM::Embedding.new(vectors: [0.1, 0.2], model: "m")
      emb.input_tokens.should eq(0)
    end

    it "reports dimensions as the flat vector length" do
      CrystalLLM::Embedding.vector_dimensions([0.1, 0.2, 0.3]).should eq(3)
    end

    it "reports an embedding_count of 1" do
      CrystalLLM::Embedding.embedding_count([0.1, 0.2, 0.3]).should eq(1)
    end
  end

  describe "batch (nested) vectors" do
    it "stores a nested array of vectors" do
      vecs = [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]
      emb = CrystalLLM::Embedding.new(vectors: vecs, model: "m", input_tokens: 9)
      emb.vectors.should eq(vecs)
    end

    it "reports dimensions from the first row" do
      CrystalLLM::Embedding.vector_dimensions([[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]).should eq(3)
    end

    it "reports embedding_count as the batch size" do
      CrystalLLM::Embedding.embedding_count([[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]).should eq(3)
    end

    it "handles an empty batch without raising" do
      empty = [] of Array(Float64)
      CrystalLLM::Embedding.vector_dimensions(empty).should eq(0)
      CrystalLLM::Embedding.embedding_count(empty).should eq(0)
    end
  end
end
