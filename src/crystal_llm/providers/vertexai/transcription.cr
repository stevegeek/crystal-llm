# ported from lib/ruby_llm/providers/vertexai/transcription.rb
#   + lib/ruby_llm/providers/gemini/transcription.rb @ ruby_llm 1.16.0
#
# Vertex AI audio-transcription hooks, reopening Providers::VertexAI.
#
# In ruby_llm, `VertexAI < Gemini` and inherits the whole Gemini transcription
# surface (render_transcription_payload / parse_transcription_response / the prompt
# + generationConfig builders), overriding ONLY `transcription_url`. CrystalLLM has
# no standalone Gemini provider yet, so the Gemini transcription wire format is
# ported *directly into this VertexAI sub-file* (self-contained — mirroring how
# vertexai/chat.cr carries the Gemini chat format). When a Gemini provider lands,
# this can be lifted to a shared base.
#
# == Divergences (documented + returned) ==
#
# * URL-needs-model: ruby_llm's vertexai `transcription_url(model)` takes the model,
#   but the frozen media-pipeline hook is `transcription_url : String` (no arg) — the
#   base `Provider#transcribe` calls `transcription_url` with no model. So the model
#   is captured in `render_transcription_payload` into `@last_transcription_model`
#   (the same `@last_model` trick chat.cr uses for completion_url) and read back by
#   `transcription_url`. The pipeline always renders before building the URL, so the
#   ivar is set. Documented divergence.
#
# * `**options` (Ruby keyword splat) -> explicit `opts : Hash(String, JSON::Any)`
#   (design §11). Option keys are read as Strings: "prompt", "safety_settings",
#   "response_mime_type", "temperature", "max_output_tokens".
#
# * `response.body` is a raw String (Crest); parse JSON.parses it (Gemini's Faraday
#   json middleware pre-parses). Matches parse_completion_response (chat.cr).
#
# * ruby_llm builds a `Faraday::Multipart::FilePart`-free `Attachment.new(audio_file)`
#   and calls `attachment.encoded` / `#mime_type` / `#audio?`. The frozen pipeline
#   hands the hook an `AudioFilePart` (path + mime + filename) instead, so the render
#   reconstructs an `Attachment` from `file_part.path` to reuse the ported
#   `Attachment#encoded` (base64) — keeping the inline_data part identical. The actual
#   network POST is still DEFERRED at the Connection layer (JSON-only, no multipart),
#   but the inline_data Gemini body is NOT multipart, so the rendered payload is the
#   real wire shape (and is unit-tested).
require "json"
require "../vertexai"
require "../../provider_media"
require "../../transcription"
require "../../attachment"

module CrystalLLM
  module Providers
    class VertexAI < Provider
      DEFAULT_TRANSCRIPTION_PROMPT =
        "Transcribe the provided audio and respond with only the transcript text."

      # The model captured at render time, used to build transcription_url (which the
      # frozen hook signature can't receive a model arg through — see file header).
      @last_transcription_model : String? = nil

      def transcription_url : String
        "projects/#{@config.vertexai_project_id}/locations/#{@config.vertexai_location}/" \
        "publishers/google/models/#{@last_transcription_model}:generateContent"
      end

      def render_transcription_payload(file_part : Provider::AudioFilePart, model : String,
                                       language : String?,
                                       opts : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        @last_transcription_model = model

        attachment = Attachment.new(file_part.path)
        unless attachment.audio?
          raise UnsupportedAttachmentError.new(attachment.mime_type)
        end

        prompt = build_prompt(opts["prompt"]?.try(&.as_s?), language)

        contents = [
          JSON::Any.new({
            "role"  => JSON::Any.new("user"),
            "parts" => JSON::Any.new([
              format_text_part(prompt),
              format_audio_part(attachment),
            ]),
          } of String => JSON::Any),
        ]

        payload = {
          "contents" => JSON::Any.new(contents),
        } of String => JSON::Any

        generation_config = build_generation_config(opts)
        unless generation_config.empty?
          payload["generationConfig"] = JSON::Any.new(generation_config)
        end

        if safety = opts["safety_settings"]?
          payload["safetySettings"] = safety
        end

        payload
      end

      def parse_transcription_response(response : Crest::Response, model : String) : Transcription
        data = JSON.parse(response.body)

        text = extract_transcription_text(data) || ""

        metadata = data["usageMetadata"]?.try(&.as_h?)

        Transcription.new(
          text: text,
          model: model,
          input_tokens: metadata.try { |meta| int_at(meta["promptTokenCount"]?) },
          output_tokens: metadata.try { |meta| sum_output_tokens(meta) }
        )
      end

      # ruby_llm's build_prompt: DEFAULT + optional language + optional custom prompt.
      private def build_prompt(custom_prompt : String?, language : String?) : String
        prompt = DEFAULT_TRANSCRIPTION_PROMPT
        prompt += " Respond in the #{language} language." if language
        prompt += " #{custom_prompt}" if custom_prompt
        prompt
      end

      private def format_text_part(text : String) : JSON::Any
        JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any)
      end

      # Gemini inline_data audio part: `{ inline_data: { mime_type:, data: } }`.
      private def format_audio_part(attachment : Attachment) : JSON::Any
        JSON::Any.new({
          "inline_data" => JSON::Any.new({
            "mime_type" => JSON::Any.new(attachment.mime_type),
            "data"      => JSON::Any.new(attachment.encoded),
          } of String => JSON::Any),
        } of String => JSON::Any)
      end

      # ruby_llm's build_generation_config: responseMimeType (default text/plain),
      # optional temperature / maxOutputTokens.
      private def build_generation_config(opts : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        config = {} of String => JSON::Any

        response_mime_type =
          if opts.has_key?("response_mime_type")
            opts["response_mime_type"].as_s?
          else
            "text/plain"
          end
        config["responseMimeType"] = JSON::Any.new(response_mime_type) if response_mime_type

        if opts.has_key?("temperature")
          if temp = opts["temperature"]
            config["temperature"] = temp
          end
        end

        if max_tokens = opts["max_output_tokens"]?
          config["maxOutputTokens"] = max_tokens
        end

        config
      end

      # Joins the `candidates[0].content.parts[*].text` strings; nil if none.
      # (ruby_llm's extract_text.)
      private def extract_transcription_text(data : JSON::Any) : String?
        parts = data.dig?("candidates", 0, "content", "parts").try(&.as_a?) || [] of JSON::Any
        texts = parts.compact_map { |part| part["text"]?.try(&.as_s?) }
        return nil if texts.empty?
        texts.join
      end

      # candidatesTokenCount + thoughtsTokenCount (ruby_llm's sum_output_tokens).
      # `int_at` is the shared numeric coercer already defined on the reopened class
      # in vertexai/chat.cr (private but visible to instance methods of the same class).
      private def sum_output_tokens(metadata : Hash(String, JSON::Any)) : Int32
        candidates = int_at(metadata["candidatesTokenCount"]?) || 0
        thoughts = int_at(metadata["thoughtsTokenCount"]?) || 0
        candidates + thoughts
      end
    end
  end
end
