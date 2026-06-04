require "../spec_helper"
require "../../src/crystal_llm/providers/azure"
require "../../src/crystal_llm/providers/azure/embeddings"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

private def configured_azure(base : String = "https://my-resource.openai.azure.com") : CrystalLLM::Providers::Azure
  config = CrystalLLM::Configuration.new
  config.azure_api_key = "test"
  config.azure_api_base = base
  CrystalLLM::Providers::Azure.new(config)
end

describe "CrystalLLM::Providers::Azure embeddings" do
  describe "#embedding_url" do
    it "uses the resource-base embeddings endpoint by default" do
      provider = configured_azure("https://r.openai.azure.com")
      provider.embedding_url(model: "text-embedding-3-small")
        .should eq("https://r.openai.azure.com/openai/v1/embeddings")
    end

    it "uses the deployment-base embeddings endpoint (no default version)" do
      provider = configured_azure("https://r.openai.azure.com/openai/deployments/embed")
      provider.embedding_url(model: "embed").should eq("embeddings")
    end

    it "honors an explicit api-version on the deployment base" do
      provider = configured_azure("https://r.openai.azure.com/openai/deployments/embed?api-version=2025-01-01")
      provider.embedding_url(model: "embed").should eq("embeddings?api-version=2025-01-01")
    end

    it "uses the openai/v1 embeddings endpoint (no default version)" do
      provider = configured_azure("https://r.openai.azure.com/openai/v1")
      provider.embedding_url(model: "embed").should eq("embeddings")
    end
  end

  describe "#render_embedding_payload" do
    it "wraps a single-string input in a 1-element array (Azure always sends an array)" do
      provider = configured_azure
      payload = provider.render_embedding_payload("hello", model: "text-embedding-3-small", dimensions: nil)

      payload["model"].as_s.should eq("text-embedding-3-small")
      payload["input"].as_a.map(&.as_s).should eq(["hello"])
      payload.has_key?("dimensions").should be_false
    end

    it "passes an array input through as a JSON array" do
      provider = configured_azure
      payload = provider.render_embedding_payload(["a", "b"], model: "text-embedding-3-small", dimensions: nil)

      payload["input"].as_a.map(&.as_s).should eq(["a", "b"])
    end

    it "includes dimensions when given" do
      provider = configured_azure
      payload = provider.render_embedding_payload("hi", model: "text-embedding-3-small", dimensions: 256)

      payload["dimensions"].as_i.should eq(256)
      payload["input"].as_a.map(&.as_s).should eq(["hi"])
    end
  end

  describe "#parse_embedding_response (inherited from OpenAI)" do
    it "flattens a single vector when the input is a plain string" do
      body = <<-JSON
      {
        "model": "text-embedding-3-small",
        "data": [
          {"object": "embedding", "index": 0, "embedding": [0.1, 0.2, 0.3]}
        ],
        "usage": {"prompt_tokens": 5, "total_tokens": 5}
      }
      JSON
      provider = configured_azure
      embedding = provider.parse_embedding_response(
        build_response(200, body), model: "text-embedding-3-small", text: "hello"
      )

      embedding.model.should eq("text-embedding-3-small")
      embedding.input_tokens.should eq(5)
      vectors = embedding.vectors
      vectors.should be_a(Array(Float64))
      vectors.as(Array(Float64)).should eq([0.1, 0.2, 0.3])
    end

    it "keeps a nested batch when the input is an Array (even with one row)" do
      body = <<-JSON
      {
        "model": "text-embedding-3-small",
        "data": [
          {"object": "embedding", "index": 0, "embedding": [0.4, 0.5]}
        ],
        "usage": {"prompt_tokens": 2, "total_tokens": 2}
      }
      JSON
      provider = configured_azure
      embedding = provider.parse_embedding_response(
        build_response(200, body), model: "text-embedding-3-small", text: ["only-one"]
      )

      vectors = embedding.vectors
      vectors.should be_a(Array(Array(Float64)))
      vectors.as(Array(Array(Float64))).should eq([[0.4, 0.5]])
    end

    it "returns a nested batch for multiple inputs" do
      body = <<-JSON
      {
        "model": "text-embedding-3-small",
        "data": [
          {"object": "embedding", "index": 0, "embedding": [1.0, 2.0]},
          {"object": "embedding", "index": 1, "embedding": [3.0, 4.0]}
        ],
        "usage": {"prompt_tokens": 8, "total_tokens": 8}
      }
      JSON
      provider = configured_azure
      embedding = provider.parse_embedding_response(
        build_response(200, body), model: "text-embedding-3-small", text: ["a", "b"]
      )

      embedding.input_tokens.should eq(8)
      vectors = embedding.vectors
      vectors.should be_a(Array(Array(Float64)))
      vectors.as(Array(Array(Float64))).should eq([[1.0, 2.0], [3.0, 4.0]])
    end

    it "defaults input_tokens to 0 when usage is absent" do
      body = <<-JSON
      {
        "model": "text-embedding-3-small",
        "data": [
          {"object": "embedding", "index": 0, "embedding": [0.1]}
        ]
      }
      JSON
      provider = configured_azure
      embedding = provider.parse_embedding_response(
        build_response(200, body), model: "text-embedding-3-small", text: "hello"
      )

      embedding.input_tokens.should eq(0)
    end
  end
end
