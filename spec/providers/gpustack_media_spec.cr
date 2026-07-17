require "../spec_helper"
require "../../src/crystal_llm/provider_media"
require "../../src/crystal_llm/providers/gpustack"

# GPUStack media (embeddings) — fixture-only, no network. GPUStack subclasses
# Providers::OpenAI and (matching ruby_llm, which ships no gpustack/embeddings.rb)
# inherits OpenAI's embedding hooks verbatim. These specs assert that the inherited
# render_embedding_payload / parse_embedding_response / embedding_url behave on a
# GPUStack instance over OpenAI-compatible /v1/embeddings fixtures.

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://gpustack.test")
  )
end

private def configured_gpustack_media : CrystalLLM::Providers::GPUStack
  config = CrystalLLM::Configuration.new
  config.gpustack_api_base = "http://gpustack.local/v1"
  config.gpustack_api_key = "test"
  CrystalLLM::Providers::GPUStack.new(config)
end

describe "CrystalLLM::Providers::GPUStack media" do
  describe "#embedding_url (inherited from OpenAI)" do
    it "targets embeddings" do
      configured_gpustack_media.embedding_url(model: "bge-embed").should eq("embeddings")
    end
  end

  describe "#render_embedding_payload (inherited from OpenAI)" do
    it "renders model + input for a single string, dropping nil dimensions" do
      payload = configured_gpustack_media.render_embedding_payload(
        "hello", model: "bge-embed", dimensions: nil
      )
      payload["model"].as_s.should eq("bge-embed")
      payload["input"].as_s.should eq("hello")
      payload.has_key?("dimensions").should be_false
    end

    it "renders an array input and includes dimensions when given" do
      payload = configured_gpustack_media.render_embedding_payload(
        ["a", "b"], model: "bge-embed", dimensions: 256
      )
      payload["input"].as_a.map(&.as_s).should eq(["a", "b"])
      payload["dimensions"].as_i.should eq(256)
    end
  end

  describe "#parse_embedding_response (inherited from OpenAI)" do
    it "flattens a single vector when the input was a string" do
      body = <<-JSON
      {
        "data": [{"embedding": [0.1, 0.2, 0.3]}],
        "usage": {"prompt_tokens": 4}
      }
      JSON
      embedding = configured_gpustack_media.parse_embedding_response(
        build_response(200, body), model: "bge-embed", text: "hi"
      )
      embedding.should be_a(CrystalLLM::Embedding)
      embedding.model.should eq("bge-embed")
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
      embedding = configured_gpustack_media.parse_embedding_response(
        build_response(200, body), model: "bge-embed", text: ["only"]
      )
      vectors = embedding.vectors
      vectors.should eq([[0.1, 0.2]])
      CrystalLLM::Embedding.embedding_count(vectors).should eq(1)
    end

    it "returns a batch of vectors for multiple inputs" do
      body = <<-JSON
      {
        "data": [{"embedding": [0.1]}, {"embedding": [0.2]}],
        "usage": {"prompt_tokens": 6}
      }
      JSON
      embedding = configured_gpustack_media.parse_embedding_response(
        build_response(200, body), model: "bge-embed", text: ["a", "b"]
      )
      embedding.vectors.should eq([[0.1], [0.2]])
      embedding.input_tokens.should eq(6)
    end

    it "defaults input_tokens to 0 when usage is absent" do
      body = %({"data": [{"embedding": [0.5]}]})
      embedding = configured_gpustack_media.parse_embedding_response(
        build_response(200, body), model: "bge-embed", text: "x"
      )
      embedding.input_tokens.should eq(0)
    end
  end
end

private def gpustack_png_content : CrystalLLM::Content
  io = IO::Memory.new
  io.write(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  io.rewind
  content = CrystalLLM::Content.new("analyze this")
  content.attachments << CrystalLLM::Attachment.new(io, filename: "screenshot.png")
  content
end

# Attachment media formatting (ported from gpustack/media.rb)
describe "CrystalLLM::Providers::GPUStack::Media attachment formatting" do
  it "emits text + image_url parts with detail:'auto'" do
    result = CrystalLLM::Providers::GPUStack::Media.format_content(gpustack_png_content)
    parts = result.as_a
    parts.size.should eq(2)

    parts[0].as_h["type"].as_s.should eq("text")
    parts[0].as_h["text"].as_s.should eq("analyze this")

    img = parts[1].as_h
    img["type"].as_s.should eq("image_url")
    image_url = img["image_url"].as_h
    image_url["url"].as_s.should start_with("data:image/png;base64,")
    image_url["detail"].as_s.should eq("auto")
  end

  it "passes plain text through as a bare string" do
    CrystalLLM::Providers::GPUStack::Media.format_content("hello").as_s.should eq("hello")
  end

  it "raises UnsupportedAttachmentError for a pdf (unsupported)" do
    io = IO::Memory.new("%PDF-1.4\n".to_slice)
    io.rewind
    content = CrystalLLM::Content.new("read")
    content.attachments << CrystalLLM::Attachment.new(io, filename: "doc.pdf")
    expect_raises(CrystalLLM::UnsupportedAttachmentError) do
      CrystalLLM::Providers::GPUStack::Media.format_content(content)
    end
  end

  it "format_content is called by the provider instance" do
    config = CrystalLLM::Configuration.new
    config.gpustack_api_base = "http://gpustack.local/v1"
    config.gpustack_api_key = "test"
    provider = CrystalLLM::Providers::GPUStack.new(config)
    result = provider.format_content(gpustack_png_content)
    parts = result.as_a
    img = parts[1].as_h
    img["type"].as_s.should eq("image_url")
    img["image_url"].as_h["detail"].as_s.should eq("auto")
  end
end
