require "./spec_helper"
require "./support/stub_connection"
require "../src/crystal_llm/transcription"
require "../src/crystal_llm/providers/openai"
require "../src/crystal_llm/provider_media"

# Unit spec for the Transcription data class. ruby_llm's spec is integration/VCR
# (it exercises `RubyLLM.transcribe` against live providers); that path depends on
# the Models registry + a Provider, both DEFERRED, so we cover the data shape only.
describe CrystalLLM::Transcription do
  it "exposes the required text and model" do
    t = CrystalLLM::Transcription.new(text: "hello world", model: "whisper-1")
    t.text.should eq("hello world")
    t.model.should eq("whisper-1")
  end

  it "defaults optional attributes to nil" do
    t = CrystalLLM::Transcription.new(text: "hi", model: "whisper-1")
    t.language.should be_nil
    t.duration.should be_nil
    t.segments.should be_nil
    t.input_tokens.should be_nil
    t.output_tokens.should be_nil
  end

  it "carries the optional attributes when provided" do
    segments = [JSON.parse(%({"id": 0, "text": "hi"}))]
    t = CrystalLLM::Transcription.new(
      text: "hi", model: "whisper-1", language: "en", duration: 1.5,
      segments: segments, input_tokens: 10, output_tokens: 20
    )
    t.language.should eq("en")
    t.duration.should eq(1.5)
    t.segments.should eq(segments)
    t.segments.try(&.first.["text"].as_s).should eq("hi")
    t.input_tokens.should eq(10)
    t.output_tokens.should eq(20)
  end
end

# ---------------------------------------------------------------------------
# Offline transcription pipeline tests: render → POST multipart → parse
# (the offline analog of ruby_llm's VCR transcription specs)
# ---------------------------------------------------------------------------

AUDIO_FIXTURE_PATH = File.expand_path(
  "#{__DIR__}/fixtures/audio.wav"
)

private def configured_openai_transcribe : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "sk-test"
  CrystalLLM::Providers::OpenAI.new(config)
end

# A JSON transcription response body (like OpenAI's gpt-4o-transcribe shape).
private TRANSCRIPTION_JSON_BODY = {
  "text"     => "Hello from the fixture.",
  "language" => "en",
  "duration" => 2.5,
  "segments" => [
    {"id" => 0, "text" => "Hello from the fixture."},
  ],
  "usage" => {
    "input_tokens"  => 11,
    "output_tokens" => 7,
  },
}.to_json

# A plain-text transcription body (response_format: text).
private TRANSCRIPTION_TEXT_BODY = "plain text transcription"

describe "CrystalLLM::Provider#transcribe pipeline (offline)" do
  describe "JSON response format" do
    it "POSTs multipart to the transcription URL and returns a Transcription" do
      provider = configured_openai_transcribe
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(TRANSCRIPTION_JSON_BODY)
      provider.connection = stub

      result = provider.transcribe(AUDIO_FIXTURE_PATH, model: "whisper-1")

      # One multipart POST recorded (no JSON posts)
      stub.posts.size.should eq(0)
      stub.multipart_posts.size.should eq(1)
      url, form = stub.multipart_posts.first
      url.should eq("audio/transcriptions")

      # The form must contain the model scalar and the file part.
      form["model"].should eq("whisper-1")
      form["file"].should be_a(File)

      # Clean up the file part (the provider's ensure block does it in production;
      # in this path StubConnection#post_multipart doesn't call it).
      if (f = form["file"]?).is_a?(File)
        f.close unless f.closed?
      end

      result.should be_a(CrystalLLM::Transcription)
      result.text.should eq("Hello from the fixture.")
      result.model.should eq("whisper-1")
      result.language.should eq("en")
      result.duration.should eq(2.5)
      result.input_tokens.should eq(11)
      result.output_tokens.should eq(7)
      segs = result.segments
      segs.should_not be_nil
      segs.try(&.size).should eq(1)
    end
  end

  describe "language parameter" do
    it "includes language in the multipart payload when provided" do
      provider = configured_openai_transcribe
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(TRANSCRIPTION_JSON_BODY)
      provider.connection = stub

      provider.transcribe(AUDIO_FIXTURE_PATH, model: "whisper-1", language: "fr")

      _url, form = stub.multipart_posts.first
      form["language"].should eq("fr")

      if (f = form["file"]?).is_a?(File)
        f.close unless f.closed?
      end
    end

    it "omits language from the payload when not provided" do
      provider = configured_openai_transcribe
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(TRANSCRIPTION_JSON_BODY)
      provider.connection = stub

      provider.transcribe(AUDIO_FIXTURE_PATH, model: "whisper-1")

      _url, form = stub.multipart_posts.first
      form.has_key?("language").should be_false

      if (f = form["file"]?).is_a?(File)
        f.close unless f.closed?
      end
    end
  end

  describe "plain-text response (response_format: text)" do
    it "returns the raw body as the transcription text" do
      provider = configured_openai_transcribe
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_response(TRANSCRIPTION_TEXT_BODY)
      provider.connection = stub

      opts = {"response_format" => JSON::Any.new("text")} of String => JSON::Any
      result = provider.transcribe(AUDIO_FIXTURE_PATH, model: "whisper-1", opts: opts)

      result.text.should eq(TRANSCRIPTION_TEXT_BODY)
      result.model.should eq("whisper-1")
      result.language.should be_nil
      result.duration.should be_nil

      if (f = stub.multipart_posts.first[1]["file"]?).is_a?(File)
        f.close unless f.closed?
      end
    end
  end

  describe "#build_audio_file_part" do
    it "resolves the path, sniffs the mime, and carries the basename" do
      provider = configured_openai_transcribe
      part = provider.build_audio_file_part(AUDIO_FIXTURE_PATH)
      part.path.should eq(File.expand_path(AUDIO_FIXTURE_PATH))
      # Crystal's MIME DB maps .wav to audio/x-wav
      part.mime_type.should eq("audio/x-wav")
      part.filename.should eq("audio.wav")
    end
  end
end
