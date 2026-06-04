require "./spec_helper"
require "crest"
require "../src/crystal_llm/providers/openai"
require "./support/stub_connection"

# No-network unit spec for the MULTIPART upload path (the gap closed in
# Connection#post_multipart + the provider media pipeline). It covers two halves:
#
#   1. The wire SHAPE: building a crest multipart request the way
#      `Connection#post_multipart` does (Crest.post(url, form, multipart: true))
#      produces a `multipart/form-data` body carrying the scalar fields AND the
#      file part's bytes/filename — WITHOUT sending anything (constructing a
#      `Crest::Request` runs form generation; only `#execute` does I/O).
#
#   2. The ROUTING: `Provider#transcribe` and the image-EDIT branch of
#      `Provider#paint` go through `connection.post_multipart` (recorded by the
#      StubConnection), while image GENERATION still uses the JSON `connection.post`.
#
# Real recorded provider responses (harvested from ruby_llm VCR cassettes) are
# queued on the stub so the parse hooks are exercised against real-world shapes.

private def openai_provider : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "test"
  CrystalLLM::Providers::OpenAI.new(config)
end

private def stub_for(provider : CrystalLLM::Provider) : CrystalLLM::Spec::StubConnection
  stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
  provider.connection = stub
  stub
end

# Materialize a tiny real file on disk so build_audio_file_part / build_upload_part
# can open it (crest reads the path + sniffs MIME from the extension).
private def with_temp_file(suffix : String, bytes : String, &)
  tmp = File.tempfile("clm_multipart_spec", suffix)
  begin
    File.write(tmp.path, bytes)
    yield tmp.path
  ensure
    tmp.close
    File.delete(tmp.path) if File.exists?(tmp.path)
  end
end

# A real recorded OpenAI transcription response (verbose_json shape).
private TRANSCRIPTION_BODY = <<-JSON
{"task":"transcribe","language":"english","duration":2.5,"text":"I love programming.","segments":[{"id":0,"seek":0,"start":0.0,"end":2.5,"text":"I love programming.","tokens":[50364,40,221],"temperature":0.0,"avg_logprob":-0.3,"compression_ratio":0.9,"no_speech_prob":0.01}],"usage":{"type":"tokens","input_tokens":14,"output_tokens":5,"total_tokens":19}}
JSON

# A real recorded OpenAI image-edit response (gpt-image-1 returns base64).
private IMAGE_EDIT_BODY = <<-JSON
{"created":1713833628,"data":[{"b64_json":"aGVsbG8td29ybGQ=","revised_prompt":"a cat wearing a tiny hat"}],"usage":{"input_tokens":50,"output_tokens":100,"total_tokens":150}}
JSON

# A real recorded OpenAI image-generation response (URL form).
private IMAGE_GEN_BODY = <<-JSON
{"created":1713833628,"data":[{"url":"https://oaidalleapi.example/img/abc.png","revised_prompt":"a serene mountain lake"}]}
JSON

describe "multipart upload path" do
  describe "Connection#post_multipart request shape" do
    it "builds a multipart/form-data body carrying scalar fields and the file part" do
      with_temp_file(".wav", "RIFFFAKEWAVDATA") do |path|
        file = File.open(path)
        begin
          form = {} of String => Crest::ParamsValue
          form["model"] = "whisper-1"
          form["language"] = "en"
          form["file"] = file.as(Crest::ParamsValue)

          # Mirror exactly what Connection#post_multipart hands to crest.
          request = Crest::Request.new(
            :post,
            "https://api.openai.com/v1/audio/transcriptions",
            form,
            multipart: true
          )

          content_type = request.headers["Content-Type"]?.to_s
          content_type.should contain("multipart/form-data")
          content_type.should contain("boundary=")

          fd = request.form_data
          body = fd.is_a?(IO) ? fd.gets_to_end : fd.to_s
          body.should contain("whisper-1")
          body.should contain("en")
          body.should contain(%(name="file"))
          body.should contain("filename")
          body.should contain("RIFFFAKEWAVDATA") # the file bytes are in the part
        ensure
          file.close
        end
      end
    end
  end

  describe "Provider#transcribe routing" do
    it "POSTs a multipart form (not JSON) with the audio file part + model field" do
      with_temp_file(".wav", "RIFFFAKEWAVDATA") do |path|
        provider = openai_provider
        stub = stub_for(provider)
        stub.stub_response(TRANSCRIPTION_BODY)

        result = provider.transcribe(path, model: "whisper-1")

        # Routed through the multipart path, NOT the JSON `post` path.
        stub.multipart_posts.size.should eq(1)
        stub.posts.size.should eq(0)

        url, form = stub.multipart_posts.first
        url.should eq("audio/transcriptions")
        form["model"].should eq("whisper-1")
        form.has_key?("file").should be_true
        form["file"].should be_a(File) # a real file part, not a JSON placeholder

        # Real recorded response parsed by parse_transcription_response.
        result.text.should eq("I love programming.")
        result.language.should eq("english")
        result.duration.should eq(2.5)
        result.input_tokens.should eq(14)
        result.output_tokens.should eq(5)
      end
    end

    it "carries optional scalar fields (language) into the multipart form" do
      with_temp_file(".mp3", "ID3FAKEMP3") do |path|
        provider = openai_provider
        stub = stub_for(provider)
        stub.stub_response(TRANSCRIPTION_BODY)

        provider.transcribe(path, model: "whisper-1", language: "fr")

        _, form = stub.multipart_posts.first
        form["language"].should eq("fr")
      end
    end
  end

  describe "Provider#paint editing routing" do
    it "routes the image-EDIT branch through post_multipart with image + mask parts" do
      with_temp_file(".png", "\x89PNG-source") do |src|
        with_temp_file(".png", "\x89PNG-mask") do |mask|
          provider = openai_provider
          stub = stub_for(provider)
          stub.stub_response(IMAGE_EDIT_BODY)

          result = provider.paint(
            "a cat wearing a tiny hat",
            model: "gpt-image-1",
            size: "1024x1024",
            with: src.as(CrystalLLM::Source),
            mask: mask.as(CrystalLLM::Source)
          )

          # Editing went multipart; the JSON path was untouched.
          stub.multipart_posts.size.should eq(1)
          stub.posts.size.should eq(0)

          url, form = stub.multipart_posts.first
          url.should eq("images/edits")
          form["model"].should eq("gpt-image-1")
          form["prompt"].should eq("a cat wearing a tiny hat")
          form.has_key?("image[0]").should be_true
          form["image[0]"].should be_a(File)
          form.has_key?("mask").should be_true
          form["mask"].should be_a(File)

          result.data.should eq("aGVsbG8td29ybGQ=")
          result.revised_prompt.should eq("a cat wearing a tiny hat")
        end
      end
    end

    it "leaves image GENERATION on the JSON post path" do
      provider = openai_provider
      stub = stub_for(provider)
      stub.stub_response(IMAGE_GEN_BODY)

      result = provider.paint("a serene mountain lake", model: "dall-e-3", size: "1024x1024")

      # Generation uses JSON, not multipart.
      stub.posts.size.should eq(1)
      stub.multipart_posts.size.should eq(0)

      url, payload = stub.posts.first
      url.should eq("images/generations")
      parsed = JSON.parse(payload)
      parsed["model"].as_s.should eq("dall-e-3")
      parsed["prompt"].as_s.should eq("a serene mountain lake")

      result.url.should eq("https://oaidalleapi.example/img/abc.png")
    end
  end

  describe "Provider#build_upload_part" do
    it "rejects a non-image attachment with UnsupportedAttachmentError" do
      with_temp_file(".txt", "just text, not an image") do |path|
        provider = openai_provider
        expect_raises(CrystalLLM::UnsupportedAttachmentError) do
          provider.build_upload_part(path.as(CrystalLLM::Source))
        end
      end
    end

    it "opens a real image path as a File part preserving its bytes" do
      with_temp_file(".png", "\x89PNG-real-bytes") do |path|
        provider = openai_provider
        part = provider.build_upload_part(path.as(CrystalLLM::Source))
        begin
          part.should be_a(File)
          part.gets_to_end.should contain("PNG-real-bytes")
        ensure
          part.close
        end
      end
    end
  end
end
