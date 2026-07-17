require "../spec_helper"
require "../../src/crystal_llm/provider_media"
require "../../src/crystal_llm/providers/ollama"

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

private def ollama_png_content : CrystalLLM::Content
  io = IO::Memory.new
  io.write(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  io.rewind
  content = CrystalLLM::Content.new("describe this")
  content.attachments << CrystalLLM::Attachment.new(io, filename: "photo.png")
  content
end

# Attachment media formatting (ported from ollama/media.rb)
describe "CrystalLLM::Providers::Ollama::Media attachment formatting" do
  it "emits text + image_url parts with detail:'auto'" do
    result = CrystalLLM::Providers::Ollama::Media.format_content(ollama_png_content)
    parts = result.as_a
    parts.size.should eq(2)

    parts[0].as_h["type"].as_s.should eq("text")
    parts[0].as_h["text"].as_s.should eq("describe this")

    img = parts[1].as_h
    img["type"].as_s.should eq("image_url")
    image_url = img["image_url"].as_h
    image_url["url"].as_s.should start_with("data:image/png;base64,")
    image_url["detail"].as_s.should eq("auto")
  end

  it "passes plain text through as a bare string" do
    CrystalLLM::Providers::Ollama::Media.format_content("hello").as_s.should eq("hello")
  end

  it "raises UnsupportedAttachmentError for audio attachments (unsupported)" do
    io = IO::Memory.new("RIFF\x00\x00\x00\x00WAVEfmt ".to_slice)
    io.rewind
    content = CrystalLLM::Content.new("listen")
    content.attachments << CrystalLLM::Attachment.new(io, filename: "sound.wav")
    expect_raises(CrystalLLM::UnsupportedAttachmentError) do
      CrystalLLM::Providers::Ollama::Media.format_content(content)
    end
  end

  it "format_content is called by the provider instance" do
    config = CrystalLLM::Configuration.new
    config.ollama_api_base = "http://localhost:11434/v1"
    config.ollama_api_key = "test"
    provider = CrystalLLM::Providers::Ollama.new(config)
    result = provider.format_content(ollama_png_content)
    parts = result.as_a
    img = parts[1].as_h
    img["type"].as_s.should eq("image_url")
    img["image_url"].as_h["detail"].as_s.should eq("auto")
  end
end
