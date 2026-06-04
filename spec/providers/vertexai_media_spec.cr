require "../spec_helper"
require "../../src/crystal_llm/provider_media"
require "../../src/crystal_llm/providers/vertexai"
require "../../src/crystal_llm/providers/vertexai/embeddings"
require "../../src/crystal_llm/providers/vertexai/transcription"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_vertexai : CrystalLLM::Providers::VertexAI
  config = CrystalLLM::Configuration.new
  config.vertexai_project_id = "my-project"
  config.vertexai_location = "us-central1"
  config.vertexai_service_account_key = "test"
  CrystalLLM::Providers::VertexAI.new(config)
end

private AUDIO_FIXTURE = File.expand_path("../fixtures/audio.wav", __DIR__)

describe "CrystalLLM::Providers::VertexAI media" do
  describe "#embedding_url" do
    it "builds the projects/.../models/<m>:predict path" do
      url = configured_vertexai.embedding_url(model: "text-embedding-005")
      url.should eq(
        "projects/my-project/locations/us-central1/" \
        "publishers/google/models/text-embedding-005:predict"
      )
    end
  end

  describe "#render_embedding_payload" do
    it "wraps a single string as one instance, dropping nil dimensions" do
      payload = configured_vertexai.render_embedding_payload(
        "hello", model: "text-embedding-005", dimensions: nil
      )
      instances = payload["instances"].as_a
      instances.size.should eq(1)
      instances[0].as_h["content"].as_s.should eq("hello")
      payload.has_key?("parameters").should be_false
    end

    it "renders an array input and includes outputDimensionality when given" do
      payload = configured_vertexai.render_embedding_payload(
        ["a", "b"], model: "text-embedding-005", dimensions: 256
      )
      instances = payload["instances"].as_a.map(&.as_h.["content"].as_s)
      instances.should eq(["a", "b"])
      payload["parameters"].as_h["outputDimensionality"].as_i.should eq(256)
    end
  end

  describe "#parse_embedding_response" do
    it "flattens a single vector when the input was a string" do
      body = <<-JSON
      {
        "predictions": [
          {"embeddings": {"values": [0.1, 0.2, 0.3]}}
        ]
      }
      JSON
      embedding = configured_vertexai.parse_embedding_response(
        build_response(200, body), model: "text-embedding-005", text: "hi"
      )
      embedding.should be_a(CrystalLLM::Embedding)
      embedding.model.should eq("text-embedding-005")
      embedding.input_tokens.should eq(0)
      vectors = embedding.vectors
      vectors.should eq([0.1, 0.2, 0.3])
      CrystalLLM::Embedding.vector_dimensions(vectors).should eq(3)
      CrystalLLM::Embedding.embedding_count(vectors).should eq(1)
    end

    it "keeps a nested batch when the input was an array (even of size 1)" do
      body = <<-JSON
      {
        "predictions": [
          {"embeddings": {"values": [0.1, 0.2]}}
        ]
      }
      JSON
      embedding = configured_vertexai.parse_embedding_response(
        build_response(200, body), model: "text-embedding-005", text: ["only"]
      )
      embedding.vectors.should eq([[0.1, 0.2]])
      CrystalLLM::Embedding.embedding_count(embedding.vectors).should eq(1)
    end

    it "returns a batch of vectors for multiple inputs" do
      body = <<-JSON
      {
        "predictions": [
          {"embeddings": {"values": [0.1]}},
          {"embeddings": {"values": [0.2]}}
        ]
      }
      JSON
      embedding = configured_vertexai.parse_embedding_response(
        build_response(200, body), model: "text-embedding-005", text: ["a", "b"]
      )
      embedding.vectors.should eq([[0.1], [0.2]])
      embedding.input_tokens.should eq(0)
    end
  end

  describe "#transcription_url" do
    it "builds the projects/.../models/<m>:generateContent path from the rendered model" do
      provider = configured_vertexai
      # render captures the model into @last_transcription_model
      provider.render_transcription_payload(
        provider.build_audio_file_part(AUDIO_FIXTURE),
        model: "gemini-2.0-flash", language: nil, opts: {} of String => JSON::Any
      )
      provider.transcription_url.should eq(
        "projects/my-project/locations/us-central1/" \
        "publishers/google/models/gemini-2.0-flash:generateContent"
      )
    end
  end

  describe "#render_transcription_payload" do
    it "renders a user contents entry with the prompt + inline audio data" do
      provider = configured_vertexai
      payload = provider.render_transcription_payload(
        provider.build_audio_file_part(AUDIO_FIXTURE),
        model: "gemini-2.0-flash", language: nil, opts: {} of String => JSON::Any
      )

      contents = payload["contents"].as_a
      contents.size.should eq(1)
      entry = contents[0].as_h
      entry["role"].as_s.should eq("user")

      parts = entry["parts"].as_a
      parts[0].as_h["text"].as_s.should eq(
        "Transcribe the provided audio and respond with only the transcript text."
      )
      inline = parts[1].as_h["inline_data"].as_h
      inline["mime_type"].as_s.should eq("audio/wav")
      inline["data"].as_s.should eq("UklGRiQAAABXQVZFZm10IA==")

      # default generationConfig responseMimeType is text/plain
      payload["generationConfig"].as_h["responseMimeType"].as_s.should eq("text/plain")
    end

    it "appends a language clause and a custom prompt to the instruction" do
      provider = configured_vertexai
      opts = {"prompt" => JSON::Any.new("Use casing.")} of String => JSON::Any
      payload = provider.render_transcription_payload(
        provider.build_audio_file_part(AUDIO_FIXTURE),
        model: "gemini-2.0-flash", language: "Spanish", opts: opts
      )
      prompt = payload["contents"].as_a[0].as_h["parts"].as_a[0].as_h["text"].as_s
      prompt.should eq(
        "Transcribe the provided audio and respond with only the transcript text. " \
        "Respond in the Spanish language. Use casing."
      )
    end

    it "wires temperature / maxOutputTokens / safetySettings opts" do
      provider = configured_vertexai
      opts = {
        "temperature"       => JSON::Any.new(0.0),
        "max_output_tokens" => JSON::Any.new(128_i64),
        "safety_settings"   => JSON::Any.new([JSON::Any.new("x")]),
      } of String => JSON::Any
      payload = provider.render_transcription_payload(
        provider.build_audio_file_part(AUDIO_FIXTURE),
        model: "gemini-2.0-flash", language: nil, opts: opts
      )
      gc = payload["generationConfig"].as_h
      gc["temperature"].as_f.should eq(0.0)
      gc["maxOutputTokens"].as_i.should eq(128)
      payload["safetySettings"].as_a.map(&.as_s).should eq(["x"])
    end

    it "raises UnsupportedAttachmentError for a non-audio file" do
      provider = configured_vertexai
      text_fixture = File.expand_path("../fixtures/ruby.txt", __DIR__)
      part = CrystalLLM::Provider::AudioFilePart.new(
        path: text_fixture, mime_type: "text/plain", filename: "ruby.txt"
      )
      expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        provider.render_transcription_payload(
          part, model: "gemini-2.0-flash", language: nil, opts: {} of String => JSON::Any
        )
      end
    end
  end

  describe "#parse_transcription_response" do
    it "joins candidate text parts and reads usage tokens" do
      body = <<-JSON
      {
        "candidates": [
          {"content": {"parts": [{"text": "hello "}, {"text": "world"}]}}
        ],
        "usageMetadata": {
          "promptTokenCount": 12,
          "candidatesTokenCount": 3,
          "thoughtsTokenCount": 2
        }
      }
      JSON
      t = configured_vertexai.parse_transcription_response(
        build_response(200, body), model: "gemini-2.0-flash"
      )
      t.text.should eq("hello world")
      t.model.should eq("gemini-2.0-flash")
      t.input_tokens.should eq(12)
      t.output_tokens.should eq(5)
    end

    it "returns empty text and nil tokens when fields are absent" do
      body = %({"candidates": []})
      t = configured_vertexai.parse_transcription_response(
        build_response(200, body), model: "gemini-2.0-flash"
      )
      t.text.should eq("")
      t.input_tokens.should be_nil
      t.output_tokens.should be_nil
    end
  end
end
