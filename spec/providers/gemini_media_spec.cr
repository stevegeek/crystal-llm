require "../spec_helper"
require "../../src/crystal_llm/provider_media"
require "../../src/crystal_llm/providers/gemini"
require "../../src/crystal_llm/providers/gemini/embeddings"
require "../../src/crystal_llm/providers/gemini/images"
require "../../src/crystal_llm/providers/gemini/transcription"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_gemini : CrystalLLM::Providers::Gemini
  config = CrystalLLM::Configuration.new
  config.gemini_api_key = "test"
  CrystalLLM::Providers::Gemini.new(config)
end

# Writes *bytes* to a temp file with *suffix* and yields its path, cleaning up after.
private def with_temp_file(suffix : String, bytes : Bytes, &)
  path = File.join(Dir.tempdir, "gemini_media_#{Random::Secure.hex(8)}#{suffix}")
  File.write(path, bytes)
  begin
    yield path
  ensure
    File.delete(path) if File.exists?(path)
  end
end

describe "CrystalLLM::Providers::Gemini media" do
  describe "#embedding_url" do
    it "builds the batchEmbedContents path for the model" do
      configured_gemini.embedding_url(model: "text-embedding-004")
        .should eq("models/text-embedding-004:batchEmbedContents")
    end
  end

  describe "#render_embedding_payload" do
    it "wraps a single string in one request, dropping nil dimensions" do
      payload = configured_gemini.render_embedding_payload(
        "hello", model: "text-embedding-004", dimensions: nil
      )
      requests = payload["requests"].as_a
      requests.size.should eq(1)
      req = requests.first.as_h
      req["model"].as_s.should eq("models/text-embedding-004")
      parts = req["content"].as_h["parts"].as_a
      parts.first.as_h["text"].as_s.should eq("hello")
      req.has_key?("outputDimensionality").should be_false
    end

    it "renders one request per array element and includes dimensions when given" do
      payload = configured_gemini.render_embedding_payload(
        ["a", "b"], model: "text-embedding-004", dimensions: 256
      )
      requests = payload["requests"].as_a
      requests.size.should eq(2)
      requests.map { |req| req.as_h["content"].as_h["parts"].as_a.first.as_h["text"].as_s }
        .should eq(["a", "b"])
      requests.first.as_h["outputDimensionality"].as_i.should eq(256)
    end
  end

  describe "#parse_embedding_response" do
    it "flattens a single vector when the input was a string" do
      body = <<-JSON
      {"embeddings": [{"values": [0.1, 0.2, 0.3]}]}
      JSON
      embedding = configured_gemini.parse_embedding_response(
        build_response(200, body), model: "text-embedding-004", text: "hi"
      )
      embedding.should be_a(CrystalLLM::Embedding)
      embedding.model.should eq("text-embedding-004")
      embedding.input_tokens.should eq(0)
      embedding.vectors.should eq([0.1, 0.2, 0.3])
      CrystalLLM::Embedding.embedding_count(embedding.vectors).should eq(1)
    end

    it "keeps a nested batch when the input was an array (even of size 1)" do
      body = %({"embeddings": [{"values": [0.5, 0.6]}]})
      embedding = configured_gemini.parse_embedding_response(
        build_response(200, body), model: "m", text: ["only"]
      )
      embedding.vectors.should eq([[0.5, 0.6]])
      CrystalLLM::Embedding.embedding_count(embedding.vectors).should eq(1)
    end

    it "returns a batch of vectors for multiple inputs" do
      body = %({"embeddings": [{"values": [0.1]}, {"values": [0.2]}]})
      embedding = configured_gemini.parse_embedding_response(
        build_response(200, body), model: "m", text: ["a", "b"]
      )
      embedding.vectors.should eq([[0.1], [0.2]])
    end
  end

  describe "#render_image_payload / #images_url" do
    it "renders the Imagen predict payload, ignoring size + params" do
      provider = configured_gemini
      params = {"quality" => JSON::Any.new("hd")} of String => JSON::Any
      payload = provider.render_image_payload(
        "a cat", model: "imagen-3.0-generate-002", size: "1024x1024",
        with: nil, mask: nil, params: params
      )
      instances = payload["instances"].as_a
      instances.first.as_h["prompt"].as_s.should eq("a cat")
      payload["parameters"].as_h["sampleCount"].as_i.should eq(1)
      payload.has_key?("size").should be_false
      payload.has_key?("quality").should be_false

      # images_url reads the @model_id set by the render hook above.
      provider.images_url(with: nil, mask: nil).should eq("models/imagen-3.0-generate-002:predict")
    end

    it "raises if images_url is called before the render hook sets the model" do
      expect_raises(CrystalLLM::Error, /requires render_image_payload/) do
        configured_gemini.images_url(with: nil, mask: nil)
      end
    end
  end

  describe "#parse_image_response" do
    it "builds a base64 Image from a predictions entry" do
      body = <<-JSON
      {"predictions": [{"bytesBase64Encoded": "aGVsbG8=", "mimeType": "image/jpeg"}]}
      JSON
      image = configured_gemini.parse_image_response(build_response(200, body), model: "imagen-3.0-generate-002")
      image.base64?.should be_true
      image.data.should eq("aGVsbG8=")
      image.mime_type.should eq("image/jpeg")
      image.model_id.should eq("imagen-3.0-generate-002")
    end

    it "defaults mime_type to image/png when omitted" do
      body = %({"predictions": [{"bytesBase64Encoded": "aGk="}]})
      image = configured_gemini.parse_image_response(build_response(200, body), model: "m")
      image.mime_type.should eq("image/png")
    end

    it "raises when bytesBase64Encoded is missing" do
      expect_raises(CrystalLLM::Error, /Unexpected response format/) do
        configured_gemini.parse_image_response(build_response(200, %({"predictions": [{}]})), model: "m")
      end
    end
  end

  describe "paint input validation" do
    it "rejects with:/mask: via the base validate_paint_inputs! (Gemini has no edit path)" do
      expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        configured_gemini.validate_paint_inputs!(with: "img.png", mask: nil)
      end
    end

    it "permits a plain generation (no with:/mask:)" do
      configured_gemini.validate_paint_inputs!(with: nil, mask: nil).should be_nil
    end
  end

  describe "#transcription_url" do
    it "raises before the render hook sets the model" do
      expect_raises(CrystalLLM::Error, /requires render_transcription_payload/) do
        configured_gemini.transcription_url
      end
    end
  end

  describe "#render_transcription_payload" do
    it "renders contents with the prompt + inline audio part and sets the model" do
      with_temp_file(".mp3", "ID3-fake-audio".to_slice) do |path|
        provider = configured_gemini
        part = provider.build_audio_file_part(path)
        payload = provider.render_transcription_payload(
          part, model: "gemini-2.5-flash", language: nil, opts: {} of String => JSON::Any
        )

        contents = payload["contents"].as_a
        parts = contents.first.as_h["parts"].as_a
        contents.first.as_h["role"].as_s.should eq("user")
        parts.first.as_h["text"].as_s.should eq(
          "Transcribe the provided audio and respond with only the transcript text."
        )
        inline = parts[1].as_h["inline_data"].as_h
        inline["mime_type"].as_s.should eq("audio/mpeg")
        inline["data"].as_s.should_not be_empty
        # default generationConfig responseMimeType is text/plain
        payload["generationConfig"].as_h["responseMimeType"].as_s.should eq("text/plain")

        provider.transcription_url.should eq("models/gemini-2.5-flash:generateContent")
      end
    end

    it "appends a language clause and a custom prompt, and honors temperature" do
      with_temp_file(".mp3", "audio".to_slice) do |path|
        provider = configured_gemini
        part = provider.build_audio_file_part(path)
        opts = {
          "prompt"      => JSON::Any.new("Focus on names."),
          "temperature" => JSON::Any.new(0.2),
        } of String => JSON::Any
        payload = provider.render_transcription_payload(
          part, model: "gemini-2.5-flash", language: "French", opts: opts
        )
        prompt = payload["contents"].as_a.first.as_h["parts"].as_a.first.as_h["text"].as_s
        prompt.should contain("Respond in the French language.")
        prompt.should contain("Focus on names.")
        payload["generationConfig"].as_h["temperature"].as_f.should eq(0.2)
      end
    end

    it "raises UnsupportedAttachmentError for a non-audio file" do
      with_temp_file(".txt", "hello".to_slice) do |path|
        provider = configured_gemini
        part = provider.build_audio_file_part(path)
        expect_raises(CrystalLLM::UnsupportedAttachmentError) do
          provider.render_transcription_payload(
            part, model: "gemini-2.5-flash", language: nil, opts: {} of String => JSON::Any
          )
        end
      end
    end
  end

  describe "#parse_transcription_response" do
    it "joins candidate text parts and sums output tokens (candidates + thoughts)" do
      body = <<-JSON
      {
        "candidates": [
          {"content": {"parts": [{"text": "hello "}, {"text": "world"}]}}
        ],
        "usageMetadata": {
          "promptTokenCount": 11,
          "candidatesTokenCount": 3,
          "thoughtsTokenCount": 2
        }
      }
      JSON
      t = configured_gemini.parse_transcription_response(build_response(200, body), model: "gemini-2.5-flash")
      t.text.should eq("hello world")
      t.model.should eq("gemini-2.5-flash")
      t.input_tokens.should eq(11)
      t.output_tokens.should eq(5)
    end

    it "returns empty text and nil tokens when there are no candidates / usage" do
      t = configured_gemini.parse_transcription_response(build_response(200, "{}"), model: "m")
      t.text.should eq("")
      t.input_tokens.should be_nil
      t.output_tokens.should be_nil
    end
  end
end
