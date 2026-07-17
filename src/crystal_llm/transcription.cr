# ported from lib/ruby_llm/transcription.rb @ ruby_llm 1.16.0
require "json"

module CrystalLLM
  # Represents a transcription of audio content.
  #
  # Divergences from ruby_llm:
  # - `segments`/`words` are wire data (arrays of provider-shaped JSON objects), so
  #   they are typed `Array(JSON::Any)?` rather than Ruby's untyped Array (design §11).
  # - `Transcription.transcribe` (the class method) resolves the model via the Models
  #   registry and dispatches to a Provider instance; it lives in `provider_media.cr`.
  class Transcription
    getter text : String
    getter model : String
    getter language : String?
    getter duration : Float64?
    getter segments : Array(JSON::Any)?

    # Word-level timestamps (ruby_llm 1.16.0 / a27cc36a). Populated only when the
    # provider's transcription response includes a `words` array (e.g. OpenAI's
    # verbose_json response_format with `timestamp_granularities: [word]`).
    getter words : Array(JSON::Any)?
    getter input_tokens : Int32?
    getter output_tokens : Int32?

    def initialize(text : String, model : String, language : String? = nil,
                   duration : Float64? = nil, segments : Array(JSON::Any)? = nil,
                   words : Array(JSON::Any)? = nil,
                   input_tokens : Int32? = nil, output_tokens : Int32? = nil)
      @text = text
      @model = model
      @language = language
      @duration = duration
      @segments = segments
      @words = words
      @input_tokens = input_tokens
      @output_tokens = output_tokens
    end

    # `Transcription.transcribe(audio_file, **kwargs)` (the class-method entry point)
    # resolves the model via the Models registry and dispatches to a Provider's
    # `#transcribe`. It lives in `provider_media.cr`, alongside the transcribe pipeline.
  end
end
