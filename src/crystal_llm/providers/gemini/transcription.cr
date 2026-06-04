# ported from lib/ruby_llm/providers/gemini/transcription.rb @ ruby_llm 1.15.0
#
# Gemini audio-transcription hooks (transcription_url / render_transcription_payload
# / parse_transcription_response + the prompt/generation-config helpers), reopening
# Providers::Gemini. Gemini has no dedicated transcription endpoint: it transcribes
# by sending the audio as an inline_data part to `:generateContent` with a
# transcribe instruction, then reads the candidate text back. parse therefore mirrors
# the chat-completion candidate/usageMetadata shape.
#
# Structural template: providers/openai/transcription.cr. The payload/parse SHAPES
# follow gemini/transcription.rb (NOT the OpenAI wire shape).
#
# Divergences from ruby_llm:
# - `response.body` is a raw JSON String (Crest); parse JSON.parses it.
# - ruby_llm's Gemini transcription overrides `Provider#transcribe` itself to build
#   an `Attachment.new(audio_file)` (so it can read `.encoded`/`.audio?`/`.mime_type`)
#   and route via `transcription_url(model)`. The port keeps the SHARED pipeline
#   (provider_media.cr's `#transcribe`), which hands the hook an `AudioFilePart`
#   (path/mime/filename). render_transcription_payload reconstructs an `Attachment`
#   from `file_part.path` to obtain the base64 bytes + the audio? check — the same
#   information ruby_llm's Attachment carried. This avoids overriding the pipeline.
# - The `@model` ivar pattern: ruby_llm's `transcription_url(model)` takes the model
#   arg; the port's hook takes none (Provider#transcribe passes none), so it reads
#   the already-established `@model_id` ivar (set in render_transcription_payload),
#   matching gemini/chat.cr's completion_url coupling. transcription_url raises if
#   render hasn't run first (render runs before url in Provider#transcribe).
# - `**options` (Ruby keyword splat) → an explicit `opts : Hash(String, JSON::Any)`
#   bag (design §11). Option keys are read as Strings: `prompt`, `response_mime_type`,
#   `temperature`, `max_output_tokens`, `safety_settings`.
# - `language` is a first-class keyword (Provider#transcribe passes it through).
require "json"
require "../gemini"
require "../../provider_media"
require "../../transcription"
require "../../attachment"

module CrystalLLM
  module Providers
    class Gemini < Provider
      # Default instruction prepended to every Gemini transcription request
      # (ruby_llm's `Transcription::DEFAULT_PROMPT`).
      TRANSCRIBE_DEFAULT_PROMPT =
        "Transcribe the provided audio and respond with only the transcript text."

      def transcription_url : String
        model = @model_id || raise Error.new(
          "Gemini transcription_url requires render_transcription_payload to set the model first"
        )
        "models/#{model}:generateContent"
      end

      def render_transcription_payload(file_part : Provider::AudioFilePart, model : String,
                                       language : String?, opts : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        @model_id = model
        attachment = Attachment.new(file_part.path)
        raise UnsupportedAttachmentError.new(attachment.mime_type) unless attachment.audio?

        prompt = build_transcription_prompt(opts["prompt"]?.try(&.as_s?), language)
        audio_part = format_audio_part(attachment)

        parts = [
          JSON::Any.new({"text" => JSON::Any.new(prompt)} of String => JSON::Any),
          audio_part,
        ]
        content = JSON::Any.new({
          "role"  => JSON::Any.new("user"),
          "parts" => JSON::Any.new(parts),
        } of String => JSON::Any)

        payload = {
          "contents" => JSON::Any.new([content]),
        } of String => JSON::Any

        generation_config = build_generation_config(opts)
        payload["generationConfig"] = JSON::Any.new(generation_config) unless generation_config.empty?
        if safety = opts["safety_settings"]?
          payload["safetySettings"] = safety
        end

        payload
      end

      def parse_transcription_response(response : Crest::Response, model : String) : Transcription
        data = JSON.parse(response.body).as_h?
        text = data ? extract_candidate_text(data) : nil
        input_tokens, output_tokens = extract_transcription_usage(data)

        Transcription.new(
          text: text || "",
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens
        )
      end

      # An `{inline_data: {mime_type, data: base64}}` audio part (ruby_llm's
      # `format_audio_part`).
      private def format_audio_part(attachment : Attachment) : JSON::Any
        JSON::Any.new({
          "inline_data" => JSON::Any.new({
            "mime_type" => JSON::Any.new(attachment.mime_type),
            "data"      => JSON::Any.new(attachment.encoded),
          } of String => JSON::Any),
        } of String => JSON::Any)
      end

      # Builds the `generationConfig` object from opts. ruby_llm's
      # `build_generation_config` (responseMimeType defaults to text/plain).
      private def build_generation_config(opts : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        config = {} of String => JSON::Any

        response_mime_type = opts.has_key?("response_mime_type") ? opts["response_mime_type"]?.try(&.as_s?) : "text/plain"
        config["responseMimeType"] = JSON::Any.new(response_mime_type) if response_mime_type

        if opts.has_key?("temperature")
          config["temperature"] = opts["temperature"]
        end
        if max_tokens = opts["max_output_tokens"]?
          config["maxOutputTokens"] = max_tokens
        end

        config
      end

      # Builds the transcribe instruction prompt (ruby_llm's `build_prompt`):
      # default + optional "Respond in <language>." + optional custom suffix.
      private def build_transcription_prompt(custom_prompt : String?, language : String?) : String
        prompt = TRANSCRIBE_DEFAULT_PROMPT
        prompt += " Respond in the #{language} language." if language
        prompt += " #{custom_prompt}" if custom_prompt
        prompt
      end

      # Joins all `text` parts of the first candidate (ruby_llm's `extract_text`),
      # or nil if there is no candidate / no text parts.
      private def extract_candidate_text(data : Hash(String, JSON::Any)) : String?
        candidate = data["candidates"]?.try(&.as_a?).try(&.first?).try(&.as_h?)
        return nil unless candidate

        parts = candidate.dig?("content", "parts").try(&.as_a?) || [] of JSON::Any
        texts = parts.compact_map { |part| part.as_h?.try(&.["text"]?).try(&.as_s?) }
        texts.empty? ? nil : texts.join
      end

      # Extracts {input_tokens, output_tokens} from usageMetadata, summing
      # candidatesTokenCount + thoughtsTokenCount for output (ruby_llm's
      # `extract_usage` / `sum_output_tokens`).
      private def extract_transcription_usage(data : Hash(String, JSON::Any)?) : {Int32?, Int32?}
        metadata = data.try(&.["usageMetadata"]?).try(&.as_h?)
        return {nil, nil} unless metadata

        input_tokens = metadata["promptTokenCount"]?.try(&.as_i?)
        candidates = metadata["candidatesTokenCount"]?.try(&.as_i?) || 0
        thoughts = metadata["thoughtsTokenCount"]?.try(&.as_i?) || 0
        {input_tokens, candidates + thoughts}
      end
    end
  end
end
