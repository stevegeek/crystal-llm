require "./spec_helper"
require "../src/crystal_llm/transcription"

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
