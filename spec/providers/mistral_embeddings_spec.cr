require "../spec_helper"
require "../../src/crystal_llm/providers/mistral"
require "../../src/crystal_llm/providers/mistral/embeddings"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

private def configured_mistral : CrystalLLM::Providers::Mistral
  config = CrystalLLM::Configuration.new
  config.mistral_api_key = "test"
  CrystalLLM::Providers::Mistral.new(config)
end

describe "CrystalLLM::Providers::Mistral embeddings" do
  describe "#embedding_url" do
    it "POSTs to the bare embeddings endpoint" do
      configured_mistral.embedding_url(model: "mistral-embed").should eq("embeddings")
    end
  end

  describe "#render_embedding_payload" do
    it "renders model + a single-string input" do
      provider = configured_mistral
      payload = provider.render_embedding_payload("hello", model: "mistral-embed", dimensions: nil)

      payload["model"].as_s.should eq("mistral-embed")
      payload["input"].as_s.should eq("hello")
    end

    it "renders an array input as a JSON array" do
      provider = configured_mistral
      payload = provider.render_embedding_payload(["a", "b"], model: "mistral-embed", dimensions: nil)

      payload["model"].as_s.should eq("mistral-embed")
      payload["input"].as_a.map(&.as_s).should eq(["a", "b"])
    end

    it "ignores dimensions (Mistral has no dimensions parameter)" do
      provider = configured_mistral
      payload = provider.render_embedding_payload("hello", model: "mistral-embed", dimensions: 256)

      payload.has_key?("dimensions").should be_false
    end
  end

  describe "#parse_embedding_response" do
    it "flattens a single vector when input is a plain string" do
      body = <<-JSON
      {
        "model": "mistral-embed",
        "data": [
          {"object": "embedding", "index": 0, "embedding": [0.1, 0.2, 0.3]}
        ],
        "usage": {"prompt_tokens": 5, "total_tokens": 5}
      }
      JSON
      provider = configured_mistral
      embedding = provider.parse_embedding_response(
        build_response(200, body), model: "mistral-embed", text: "hello"
      )

      embedding.model.should eq("mistral-embed")
      embedding.input_tokens.should eq(5)
      vectors = embedding.vectors
      vectors.should be_a(Array(Float64))
      vectors.as(Array(Float64)).should eq([0.1, 0.2, 0.3])
    end

    it "keeps a nested batch when the input is an Array (even with one row)" do
      body = <<-JSON
      {
        "model": "mistral-embed",
        "data": [
          {"object": "embedding", "index": 0, "embedding": [0.4, 0.5]}
        ],
        "usage": {"prompt_tokens": 2, "total_tokens": 2}
      }
      JSON
      provider = configured_mistral
      embedding = provider.parse_embedding_response(
        build_response(200, body), model: "mistral-embed", text: ["only-one"]
      )

      embedding.input_tokens.should eq(2)
      vectors = embedding.vectors
      vectors.should be_a(Array(Array(Float64)))
      vectors.as(Array(Array(Float64))).should eq([[0.4, 0.5]])
    end

    it "returns a nested batch for multiple inputs" do
      body = <<-JSON
      {
        "model": "mistral-embed",
        "data": [
          {"object": "embedding", "index": 0, "embedding": [1.0, 2.0]},
          {"object": "embedding", "index": 1, "embedding": [3.0, 4.0]}
        ],
        "usage": {"prompt_tokens": 8, "total_tokens": 8}
      }
      JSON
      provider = configured_mistral
      embedding = provider.parse_embedding_response(
        build_response(200, body), model: "mistral-embed", text: ["a", "b"]
      )

      embedding.input_tokens.should eq(8)
      vectors = embedding.vectors
      vectors.should be_a(Array(Array(Float64)))
      vectors.as(Array(Array(Float64))).should eq([[1.0, 2.0], [3.0, 4.0]])
    end

    it "defaults input_tokens to 0 when usage is absent" do
      body = <<-JSON
      {
        "model": "mistral-embed",
        "data": [
          {"object": "embedding", "index": 0, "embedding": [0.1]}
        ]
      }
      JSON
      provider = configured_mistral
      embedding = provider.parse_embedding_response(
        build_response(200, body), model: "mistral-embed", text: "hello"
      )

      embedding.input_tokens.should eq(0)
    end
  end
end
