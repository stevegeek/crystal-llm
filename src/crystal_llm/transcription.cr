# ported from lib/ruby_llm/transcription.rb @ ruby_llm 1.15.0
require "json"

module CrystalLLM
  # Represents a transcription of audio content.
  #
  # Divergences from ruby_llm:
  # - `segments` is wire data (an array of provider-shaped JSON objects), so it is
  #   typed `Array(JSON::Any)?` rather than Ruby's untyped Array (design §11).
  # - `Transcription.transcribe` (the class method) requires the Models registry and a
  #   Provider instance; both are not yet ported, so it is DEFERRED (see PORTING.md).
  class Transcription
    getter text : String
    getter model : String
    getter language : String?
    getter duration : Float64?
    getter segments : Array(JSON::Any)?
    getter input_tokens : Int32?
    getter output_tokens : Int32?

    def initialize(text : String, model : String, language : String? = nil,
                   duration : Float64? = nil, segments : Array(JSON::Any)? = nil,
                   input_tokens : Int32? = nil, output_tokens : Int32? = nil)
      @text = text
      @model = model
      @language = language
      @duration = duration
      @segments = segments
      @input_tokens = input_tokens
      @output_tokens = output_tokens
    end

    # DEFERRED: `Transcription.transcribe(audio_file, **kwargs)` resolves the model via
    # the Models registry and dispatches to a Provider instance's `#transcribe`. Neither
    # Models nor Provider is ported yet, so this faithful entry point is intentionally
    # omitted rather than faked. Tracked in PORTING.md / returned as a deferral.
  end
end
