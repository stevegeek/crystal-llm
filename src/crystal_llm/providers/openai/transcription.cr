# ported from lib/ruby_llm/providers/openai/transcription.rb @ ruby_llm 1.15.0
#
# OpenAI audio-transcription hooks (transcription_url / render_transcription_payload
# / parse_transcription_response + the chunking/response_format helpers), reopening
# Providers::OpenAI.
#
# Divergences:
# - `response.body` is a raw String (Crest); when a provider returns plain text
#   (`response_format: text`), it IS the transcription text — mirroring ruby_llm's
#   `return Transcription.new(text: data, ...) if data.is_a?(String)`. We detect the
#   JSON case by attempting a parse; a parse failure (or a non-object top level) is
#   treated as the plain-text case.
# - `**options` (Ruby keyword splat) → an explicit `opts : Hash(String, JSON::Any)`
#   bag. Option keys are read as Strings (`opts["chunking_strategy"]?` etc).
# - The `file` part is NOT in the rendered payload: `render_transcription_payload`
#   returns only the non-file fields, and the media pipeline (`Provider#transcribe`)
#   adds the audio `file` part to the multipart form via `Connection#post_multipart`.
#   (Previously the file was a JSON placeholder while the multipart POST was deferred.)
# - `encode_speaker_references` maps each speaker reference to an `Attachment`
#   and emits its `#for_llm` data URL (ruby_llm: `Attachment.new(ref).for_llm`).
#   References arrive in the `JSON::Any` opts bag as an array of source Strings
#   (a path or `https?://` URL — the only sources representable on the wire bag;
#   ruby_llm also accepts IO, which has no JSON::Any representation here). Each
#   String becomes `Attachment.new(source)`, whose `#for_llm` reads the bytes and
#   returns `data:<mime>;base64,<...>` (or a `<file>` tag for text). A non-array
#   value raises (ruby_llm relies on `references.map`, i.e. an Enumerable).
require "json"
require "../openai"
require "../../attachment"
require "../../provider_media"
require "../../transcription"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      def transcription_url : String
        "audio/transcriptions"
      end

      def render_transcription_payload(_file_part : Provider::AudioFilePart, model : String,
                                       language : String?, opts : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        payload = {} of String => JSON::Any
        payload["model"] = JSON::Any.new(model)
        payload["language"] = JSON::Any.new(language) unless language.nil?

        if supports_chunking_strategy?(model, opts)
          payload["chunking_strategy"] = opts["chunking_strategy"]? || JSON::Any.new("auto")
        end

        if rf = response_format_for(model, opts)
          payload["response_format"] = rf
        end

        if prompt = opts["prompt"]?
          payload["prompt"] = prompt
        end
        if temperature = opts["temperature"]?
          payload["temperature"] = temperature
        end
        if granularities = opts["timestamp_granularities"]?
          payload["timestamp_granularities"] = granularities
        end
        if speaker_names = opts["speaker_names"]?
          payload["known_speaker_names"] = speaker_names
        end
        if opts.has_key?("speaker_references")
          payload["known_speaker_references"] = encode_speaker_references(opts["speaker_references"])
        end

        payload
      end

      # Encodes each speaker reference as an `Attachment#for_llm` value
      # (ruby_llm: `references.map { |ref| Attachment.new(ref).for_llm }`).
      # *references* is the `JSON::Any`-wrapped array from the opts bag; each
      # element is a source String (path or URL). Returns a `JSON::Any` array of
      # data-URL (or `<file>`-tag) Strings for the `known_speaker_references` field.
      def encode_speaker_references(references : JSON::Any) : JSON::Any
        refs = references.as_a? ||
               raise ArgumentError.new(
                 "speaker_references must be an array of attachment source strings, " \
                 "got #{references.raw.class}"
               )

        encoded = refs.map do |ref|
          source = ref.as_s? ||
                   raise ArgumentError.new(
                     "each speaker reference must be a source string (path/URL), " \
                     "got #{ref.raw.class}"
                   )
          JSON::Any.new(Attachment.new(source).for_llm)
        end

        JSON::Any.new(encoded)
      end

      # Returns the response_format value, or nil to omit. ruby_llm: explicit
      # `response_format` opt wins; otherwise `diarized_json` for diarize models.
      def response_format_for(model : String, opts : Hash(String, JSON::Any)) : JSON::Any?
        return opts["response_format"]? if opts.has_key?("response_format")

        model.includes?("diarize") ? JSON::Any.new("diarized_json") : nil
      end

      # ruby_llm: whisper never; explicit opt forces true; otherwise diarize models.
      def supports_chunking_strategy?(model : String, opts : Hash(String, JSON::Any)) : Bool
        return false if model.starts_with?("whisper")
        return true if opts.has_key?("chunking_strategy")

        model.includes?("diarize")
      end

      def parse_transcription_response(response : Crest::Response, model : String) : Transcription
        body = response.body
        data = try_parse_object(body)

        # Plain-text response (response_format: text): the body IS the text.
        return Transcription.new(text: body, model: model) if data.nil?

        usage = data["usage"]?.try(&.as_h?) || {} of String => JSON::Any

        Transcription.new(
          text: data["text"]?.try(&.as_s?) || "",
          model: model,
          language: data["language"]?.try(&.as_s?),
          duration: data["duration"]?.try { |dur| dur.as_f? || dur.as_i?.try(&.to_f) },
          segments: data["segments"]?.try(&.as_a?),
          input_tokens: int_at(usage["input_tokens"]?) || int_at(usage["prompt_tokens"]?),
          output_tokens: int_at(usage["output_tokens"]?) || int_at(usage["completion_tokens"]?)
        )
      end

      # Parses *body* as a JSON object, or nil if it is not a JSON object (the
      # plain-text transcription case).
      private def try_parse_object(body : String) : Hash(String, JSON::Any)?
        JSON.parse(body).as_h?
      rescue JSON::ParseException
        nil
      end
    end
  end
end
