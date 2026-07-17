require "./spec_helper"
require "./support/stub_connection"
require "../src/crystal_llm/embedding"
require "../src/crystal_llm/providers/openai"
require "../src/crystal_llm/provider_media"

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

# ---------------------------------------------------------------------------
# Offline pipeline tests: render → POST → parse via StubConnection
# (the offline analog of ruby_llm's VCR embeddings_spec.rb)
# ---------------------------------------------------------------------------

private def configured_openai_embed : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "sk-test"
  CrystalLLM::Providers::OpenAI.new(config)
end

# A minimal single-vector OpenAI embeddings response body (single text input).
private SINGLE_EMBED_BODY = {
  "object" => "list",
  "data"   => [
    {
      "object"    => "embedding",
      "index"     => 0,
      "embedding" => [0.1, 0.2, 0.3],
    },
  ],
  "model" => "text-embedding-3-small",
  "usage" => {"prompt_tokens" => 3, "total_tokens" => 3},
}.to_json

# A batch response: two vectors.
private BATCH_EMBED_BODY = {
  "object" => "list",
  "data"   => [
    {"object" => "embedding", "index" => 0, "embedding" => [0.1, 0.2]},
    {"object" => "embedding", "index" => 1, "embedding" => [0.3, 0.4]},
  ],
  "model" => "text-embedding-3-small",
  "usage" => {"prompt_tokens" => 6, "total_tokens" => 6},
}.to_json

describe "CrystalLLM::Provider#embed pipeline (offline)" do
  describe "single-text input → flat vector" do
    it "POSTs to the embeddings URL and returns a flat Embedding" do
      provider = configured_openai_embed
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(SINGLE_EMBED_BODY)
      provider.connection = stub

      result = provider.embed("hello", model: "text-embedding-3-small")

      # One POST to "embeddings"
      stub.posts.size.should eq(1)
      url, payload_str = stub.posts.first
      url.should eq("embeddings")

      # Payload contains model + input
      payload = JSON.parse(payload_str)
      payload["model"].as_s.should eq("text-embedding-3-small")
      payload["input"].as_s.should eq("hello")

      # Response is a flat vector (not a batch)
      result.model.should eq("text-embedding-3-small")
      result.input_tokens.should eq(3)
      vectors = result.vectors
      vectors.should be_a(Array(Float64))
      vectors.as(Array(Float64)).should eq([0.1, 0.2, 0.3])
    end

    it "forwards the dimensions parameter when provided" do
      provider = configured_openai_embed
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(SINGLE_EMBED_BODY)
      provider.connection = stub

      provider.embed("test", model: "text-embedding-3-small", dimensions: 256)

      payload = JSON.parse(stub.posts.first[1])
      payload["dimensions"].as_i.should eq(256)
    end

    it "omits the dimensions key when dimensions is nil" do
      provider = configured_openai_embed
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(SINGLE_EMBED_BODY)
      provider.connection = stub

      provider.embed("test", model: "text-embedding-3-small", dimensions: nil)

      payload = JSON.parse(stub.posts.first[1])
      payload.as_h.has_key?("dimensions").should be_false
    end
  end

  describe "batch input (Array(String)) → nested vectors" do
    it "sends an array input and returns a batch Embedding" do
      provider = configured_openai_embed
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(BATCH_EMBED_BODY)
      provider.connection = stub

      result = provider.embed(["hello", "world"], model: "text-embedding-3-small")

      payload = JSON.parse(stub.posts.first[1])
      payload["input"].as_a.map(&.as_s).should eq(["hello", "world"])

      # Two vectors in the response → batch (nested) shape
      result.input_tokens.should eq(6)
      vectors = result.vectors
      vectors.should be_a(Array(Array(Float64)))
      vectors.as(Array(Array(Float64))).should eq([[0.1, 0.2], [0.3, 0.4]])
    end
  end
end
