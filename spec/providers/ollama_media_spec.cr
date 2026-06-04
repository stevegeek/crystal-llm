require "../spec_helper"
require "../../src/crystal_llm/provider_media"
require "../../src/crystal_llm/providers/ollama"
require "../../src/crystal_llm/providers/ollama/embeddings"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_ollama : CrystalLLM::Providers::Ollama
  config = CrystalLLM::Configuration.new
  config.ollama_api_base = "http://localhost:11434/v1"
  config.ollama_api_key = "test"
  CrystalLLM::Providers::Ollama.new(config)
end

describe "CrystalLLM::Providers::Ollama media" do
  describe "#embedding_url" do
    it "returns the OpenAI-compatible embeddings endpoint path" do
      configured_ollama.embedding_url(model: "nomic-embed-text").should eq("embeddings")
    end
  end

  describe "#render_embedding_payload" do
    it "renders model + input for a single string, dropping nil dimensions" do
      payload = configured_ollama.render_embedding_payload(
        "hello", model: "nomic-embed-text", dimensions: nil
      )
      payload["model"].as_s.should eq("nomic-embed-text")
      payload["input"].as_s.should eq("hello")
      payload.has_key?("dimensions").should be_false
    end

    it "renders an array input and includes dimensions when given" do
      payload = configured_ollama.render_embedding_payload(
        ["a", "b"], model: "nomic-embed-text", dimensions: 512
      )
      payload["input"].as_a.map(&.as_s).should eq(["a", "b"])
      payload["dimensions"].as_i.should eq(512)
    end
  end

  describe "#parse_embedding_response" do
    it "flattens a single vector when the input was a string" do
      body = <<-JSON
      {
        "data": [{"embedding": [0.1, 0.2, 0.3]}],
        "usage": {"prompt_tokens": 4}
      }
      JSON
      embedding = configured_ollama.parse_embedding_response(
        build_response(200, body), model: "nomic-embed-text", text: "hi"
      )
      embedding.should be_a(CrystalLLM::Embedding)
      embedding.model.should eq("nomic-embed-text")
      embedding.input_tokens.should eq(4)
      vectors = embedding.vectors
      vectors.should eq([0.1, 0.2, 0.3])
      CrystalLLM::Embedding.vector_dimensions(vectors).should eq(3)
      CrystalLLM::Embedding.embedding_count(vectors).should eq(1)
    end

    it "keeps a nested batch when the input was an array (even of size 1)" do
      body = <<-JSON
      {
        "data": [{"embedding": [0.1, 0.2]}],
        "usage": {"prompt_tokens": 2}
      }
      JSON
      embedding = configured_ollama.parse_embedding_response(
        build_response(200, body), model: "nomic-embed-text", text: ["only"]
      )
      embedding.vectors.should eq([[0.1, 0.2]])
      CrystalLLM::Embedding.embedding_count(embedding.vectors).should eq(1)
    end

    it "returns a batch of vectors for multiple inputs" do
      body = <<-JSON
      {
        "data": [{"embedding": [0.1]}, {"embedding": [0.2]}],
        "usage": {"prompt_tokens": 6}
      }
      JSON
      embedding = configured_ollama.parse_embedding_response(
        build_response(200, body), model: "nomic-embed-text", text: ["a", "b"]
      )
      embedding.vectors.should eq([[0.1], [0.2]])
      embedding.input_tokens.should eq(6)
    end

    it "defaults input_tokens to 0 when usage is absent" do
      body = %({"data": [{"embedding": [0.5]}]})
      embedding = configured_ollama.parse_embedding_response(
        build_response(200, body), model: "nomic-embed-text", text: "x"
      )
      embedding.input_tokens.should eq(0)
    end
  end
end
