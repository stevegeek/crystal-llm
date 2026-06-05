require "base64"
require "../spec_helper"
require "../../src/crystal_llm/provider_media"
require "../../src/crystal_llm/providers/openai"
require "../../src/crystal_llm/providers/openai/embeddings"
require "../../src/crystal_llm/providers/openai/images"
require "../../src/crystal_llm/providers/openai/moderation"
require "../../src/crystal_llm/providers/openai/transcription"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_openai : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "test"
  CrystalLLM::Providers::OpenAI.new(config)
end

describe "CrystalLLM::Providers::OpenAI media" do
  describe "#render_embedding_payload" do
    it "renders model + input for a single string, dropping nil dimensions" do
      payload = configured_openai.render_embedding_payload(
        "hello", model: "text-embedding-3-small", dimensions: nil
      )
      payload["model"].as_s.should eq("text-embedding-3-small")
      payload["input"].as_s.should eq("hello")
      payload.has_key?("dimensions").should be_false
    end

    it "renders an array input and includes dimensions when given" do
      payload = configured_openai.render_embedding_payload(
        ["a", "b"], model: "text-embedding-3-small", dimensions: 256
      )
      payload["input"].as_a.map(&.as_s).should eq(["a", "b"])
      payload["dimensions"].as_i.should eq(256)
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
      embedding = configured_openai.parse_embedding_response(
        build_response(200, body), model: "text-embedding-3-small", text: "hi"
      )
      embedding.should be_a(CrystalLLM::Embedding)
      embedding.model.should eq("text-embedding-3-small")
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
      embedding = configured_openai.parse_embedding_response(
        build_response(200, body), model: "text-embedding-3-small", text: ["only"]
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
      embedding = configured_openai.parse_embedding_response(
        build_response(200, body), model: "text-embedding-3-small", text: ["a", "b"]
      )
      embedding.vectors.should eq([[0.1], [0.2]])
      embedding.input_tokens.should eq(6)
    end

    it "defaults input_tokens to 0 when usage is absent" do
      body = %({"data": [{"embedding": [0.5]}]})
      embedding = configured_openai.parse_embedding_response(
        build_response(200, body), model: "m", text: "x"
      )
      embedding.input_tokens.should eq(0)
    end
  end

  describe "#images_url" do
    it "routes generation vs edit by inputs" do
      provider = configured_openai
      provider.images_url(with: nil, mask: nil).should eq("images/generations")
      provider.images_url(with: "img.png", mask: nil).should eq("images/edits")
    end
  end

  describe "#render_image_payload" do
    it "renders the generation payload and merges params" do
      params = {"quality" => JSON::Any.new("hd")} of String => JSON::Any
      payload = configured_openai.render_image_payload(
        "a cat", model: "gpt-image-1.5", size: "1024x1024",
        with: nil, mask: nil, params: params
      )
      payload["model"].as_s.should eq("gpt-image-1.5")
      payload["prompt"].as_s.should eq("a cat")
      payload["n"].as_i.should eq(1)
      payload["size"].as_s.should eq("1024x1024")
      payload["quality"].as_s.should eq("hd")
    end

    it "builds a multipart edit form on the edit path (no longer deferred)" do
      tmp = File.tempfile("openai_media_spec", ".png")
      begin
        File.write(tmp.path, "\x89PNG-edit-source")
        provider = configured_openai

        # Editing now routes through the dedicated multipart form builder, while
        # render_image_payload itself only renders the generation scalar payload.
        provider.editing_image?(with: tmp.path, mask: nil).should be_true

        form = provider.render_image_edit_form(
          "edit", model: "gpt-image-1.5", size: "1024x1024",
          with: tmp.path.as(CrystalLLM::Source), mask: nil,
          params: {} of String => JSON::Any
        )
        begin
          form["model"].should eq("gpt-image-1.5")
          form["prompt"].should eq("edit")
          form.has_key?("image[0]").should be_true
          form["image[0]"].should be_a(File)
        ensure
          form.each_value { |v| v.close if v.is_a?(File) }
        end
      ensure
        tmp.close
        File.delete(tmp.path) if File.exists?(tmp.path)
      end
    end
  end

  describe "#parse_image_response" do
    it "builds an Image from a url result" do
      body = <<-JSON
      {
        "data": [{"url": "https://x/y.png", "revised_prompt": "a fluffy cat"}],
        "usage": {"input_tokens": 10}
      }
      JSON
      image = configured_openai.parse_image_response(build_response(200, body), model: "gpt-image-1.5")
      image.url.should eq("https://x/y.png")
      image.mime_type.should eq("image/png")
      image.revised_prompt.should eq("a fluffy cat")
      image.model_id.should eq("gpt-image-1.5")
      image.base64?.should be_false
    end

    it "builds a base64 Image from a b64_json result" do
      body = %({"data": [{"b64_json": "aGVsbG8="}]})
      image = configured_openai.parse_image_response(build_response(200, body), model: "gpt-image-1.5")
      image.base64?.should be_true
      image.data.should eq("aGVsbG8=")
    end

    it "raises on an empty data array" do
      expect_raises(CrystalLLM::Error, /Unexpected response format/) do
        configured_openai.parse_image_response(build_response(200, %({"data": []})), model: "m")
      end
    end
  end

  describe "#render_moderation_payload" do
    it "renders model + string input" do
      payload = configured_openai.render_moderation_payload("bad text", model: "omni-moderation-latest")
      payload["model"].as_s.should eq("omni-moderation-latest")
      payload["input"].as_s.should eq("bad text")
    end

    it "renders an array input" do
      payload = configured_openai.render_moderation_payload(["a", "b"], model: "omni-moderation-latest")
      payload["input"].as_a.map(&.as_s).should eq(["a", "b"])
    end
  end

  describe "#parse_moderation_response" do
    it "builds a Moderation with results" do
      body = <<-JSON
      {
        "id": "modr-1",
        "results": [{"flagged": true, "categories": {"hate": true}}]
      }
      JSON
      mod = configured_openai.parse_moderation_response(build_response(200, body), model: "omni-moderation-latest")
      mod.id.should eq("modr-1")
      mod.model.should eq("omni-moderation-latest")
      mod.flagged?.should be_true
      mod.flagged_categories.should contain("hate")
    end

    it "raises on an error body" do
      body = %({"error": {"message": "bad input"}})
      expect_raises(CrystalLLM::Error, "bad input") do
        configured_openai.parse_moderation_response(build_response(400, body), model: "m")
      end
    end
  end

  describe "#moderation_url / #embedding_url / #transcription_url" do
    it "returns the OpenAI endpoint paths" do
      provider = configured_openai
      provider.moderation_url.should eq("moderations")
      provider.embedding_url(model: "m").should eq("embeddings")
      provider.transcription_url.should eq("audio/transcriptions")
    end
  end

  describe "#render_transcription_payload" do
    it "renders model + file + language and omits chunking for whisper" do
      part = CrystalLLM::Provider::AudioFilePart.new(
        path: "/tmp/a.mp3", mime_type: "audio/mpeg", filename: "a.mp3"
      )
      payload = configured_openai.render_transcription_payload(
        part, model: "whisper-1", language: "en", opts: {} of String => JSON::Any
      )
      payload["model"].as_s.should eq("whisper-1")
      payload["language"].as_s.should eq("en")
      # The audio `file` is no longer a payload field — the multipart pipeline
      # (Provider#transcribe) adds the file part to the form directly.
      payload.has_key?("file").should be_false
      payload.has_key?("chunking_strategy").should be_false
      payload.has_key?("response_format").should be_false
    end

    it "adds chunking_strategy and response_format for a diarize model" do
      part = CrystalLLM::Provider::AudioFilePart.new(
        path: "/tmp/a.wav", mime_type: "audio/wav", filename: "a.wav"
      )
      payload = configured_openai.render_transcription_payload(
        part, model: "gpt-4o-transcribe-diarize", language: nil,
        opts: {} of String => JSON::Any
      )
      payload["chunking_strategy"].as_s.should eq("auto")
      payload["response_format"].as_s.should eq("diarized_json")
      payload.has_key?("language").should be_false
    end

    it "honors explicit response_format and prompt/temperature opts" do
      part = CrystalLLM::Provider::AudioFilePart.new(
        path: "/tmp/a.mp3", mime_type: "audio/mpeg", filename: "a.mp3"
      )
      opts = {
        "response_format" => JSON::Any.new("verbose_json"),
        "prompt"          => JSON::Any.new("context"),
        "temperature"     => JSON::Any.new(0.0),
      } of String => JSON::Any
      payload = configured_openai.render_transcription_payload(
        part, model: "whisper-1", language: nil, opts: opts
      )
      payload["response_format"].as_s.should eq("verbose_json")
      payload["prompt"].as_s.should eq("context")
      payload["temperature"].as_f.should eq(0.0)
    end
  end

  describe "#encode_speaker_references" do
    it "encodes a list of in-memory audio refs as for_llm data URLs" do
      alice_bytes = Bytes[0x00, 0x11, 0x22, 0x33]
      bob_bytes = Bytes[0xAA, 0xBB, 0xCC]
      alice = File.tempfile("alice", ".mp3", &.write(alice_bytes))
      bob = File.tempfile("bob", ".wav", &.write(bob_bytes))

      begin
        refs = JSON::Any.new([
          JSON::Any.new(alice.path),
          JSON::Any.new(bob.path),
        ])
        encoded = configured_openai.encode_speaker_references(refs).as_a

        encoded.size.should eq(2)
        # .mp3 -> audio/mpeg, .wav -> normalized audio/wav; both audio => data URL.
        encoded[0].as_s.should eq("data:audio/mpeg;base64,#{Base64.strict_encode(alice_bytes)}")
        encoded[1].as_s.should eq("data:audio/wav;base64,#{Base64.strict_encode(bob_bytes)}")
      ensure
        File.delete(alice.path) if File.exists?(alice.path)
        File.delete(bob.path) if File.exists?(bob.path)
      end
    end

    it "flows through render_transcription_payload into known_speaker_references" do
      ref = File.tempfile("spk", ".mp3", &.write(Bytes[0x01, 0x02]))
      begin
        part = CrystalLLM::Provider::AudioFilePart.new(
          path: "/tmp/a.mp3", mime_type: "audio/mpeg", filename: "a.mp3"
        )
        opts = {
          "speaker_references" => JSON::Any.new([JSON::Any.new(ref.path)]),
        } of String => JSON::Any
        payload = configured_openai.render_transcription_payload(
          part, model: "whisper-1", language: nil, opts: opts
        )
        refs = payload["known_speaker_references"].as_a
        refs.size.should eq(1)
        refs[0].as_s.should start_with("data:audio/mpeg;base64,")
      ensure
        File.delete(ref.path) if File.exists?(ref.path)
      end
    end

    it "raises a clear error when a reference is not a source string" do
      refs = JSON::Any.new([JSON::Any.new(42_i64)])
      expect_raises(ArgumentError, /each speaker reference must be a source string/) do
        configured_openai.encode_speaker_references(refs)
      end
    end

    it "raises a clear error when speaker_references is not an array" do
      expect_raises(ArgumentError, /must be an array/) do
        configured_openai.encode_speaker_references(JSON::Any.new("not-an-array"))
      end
    end
  end

  describe "#parse_transcription_response" do
    it "parses a JSON transcription with usage tokens" do
      body = <<-JSON
      {
        "text": "hello world",
        "language": "english",
        "duration": 1.5,
        "segments": [{"id": 0, "text": "hello world"}],
        "usage": {"input_tokens": 7, "output_tokens": 2}
      }
      JSON
      t = configured_openai.parse_transcription_response(build_response(200, body), model: "whisper-1")
      t.text.should eq("hello world")
      t.language.should eq("english")
      t.duration.should eq(1.5)
      t.input_tokens.should eq(7)
      t.output_tokens.should eq(2)
      t.segments.try(&.size).should eq(1)
    end

    it "treats a plain-text body as the transcription text" do
      t = configured_openai.parse_transcription_response(build_response(200, "just text"), model: "whisper-1")
      t.text.should eq("just text")
      t.model.should eq("whisper-1")
    end
  end

  describe "#build_audio_file_part" do
    it "expands the path and carries the basename" do
      part = configured_openai.build_audio_file_part("./a.mp3")
      part.filename.should eq("a.mp3")
      part.path.ends_with?("a.mp3").should be_true
    end
  end

  describe "Media document_attachments \"all\"" do
    it "serializes a docx to {type:file, file:{filename, file_data: data-URL}}" do
      io = IO::Memory.new
      io.write("PK\x03\x04docx-bytes".to_slice)
      io.rewind
      attachment = CrystalLLM::Attachment.new(io, filename: "report.docx")
      attachment.type.should eq(:document)
      content = CrystalLLM::Content.new("read this")
      content.attachments << attachment

      parts = CrystalLLM::Providers::OpenAI::Media.format_content(
        content, document_attachments: "all"
      ).as_a
      file_part = parts.find! { |part| part.as_h["type"].as_s == "file" }.as_h
      file_part["type"].as_s.should eq("file")
      file = file_part["file"].as_h
      file["filename"].as_s.should eq("report.docx")
      file["file_data"].as_s.should start_with(
        "data:application/vnd.openxmlformats-officedocument.wordprocessingml.document;base64,"
      )
    end

    it "rejects a docx under the default \"pdf\" strategy" do
      io = IO::Memory.new
      io.write("PK\x03\x04docx-bytes".to_slice)
      io.rewind
      content = CrystalLLM::Content.new("read this")
      content.attachments << CrystalLLM::Attachment.new(io, filename: "report.docx")

      expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        CrystalLLM::Providers::OpenAI::Media.format_content(content)
      end
    end
  end
end
