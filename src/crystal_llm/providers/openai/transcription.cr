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
# - `encode_speaker_references` (which calls `Attachment#for_llm` on each ref) is
#   DEFERRED with the attachment-provider surface (for_llm is part of that not-yet-
#   ported work). A `speaker_references` opt raises a clear "deferred" error.
require "json"
require "../openai"
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

      # DEFERRED: ruby_llm encodes each reference via `Attachment.new(ref).for_llm`
      # (the data-URL encoder), which is part of the not-yet-ported attachment-
      # provider surface. Raise a clear deferral rather than silently dropping it.
      def encode_speaker_references(references : JSON::Any) : JSON::Any
        raise NotImplementedError.new(
          "OpenAI transcription speaker_references encoding is deferred to the " \
          "attachment-provider port (needs Attachment#for_llm). " \
          "See providers/openai/transcription.cr."
        )
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
