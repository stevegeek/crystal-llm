# ported from lib/ruby_llm/providers/gemini.rb (+ gemini/{chat,streaming,tools,models,media,capabilities}.rb) @ ruby_llm 1.15.0
#
# Native Gemini (generativelanguage.googleapis.com) chat provider: text chat +
# tools + streaming + models + capabilities. Gemini has its OWN wire format
# (contents/parts, generationConfig, functionDeclarations, inline_data), NOT the
# OpenAI chat-completions shape — so this is a `< Provider` port that reuses
# OpenAI only as a STRUCTURAL template (same hooks), never its payload shape.
#
# ruby_llm splits Gemini into many `module_function` mixins included into one
# class; the Crystal port collapses chat/streaming/tools/models/media into this
# class (reopened in sub-files) and ports Capabilities as a
# `CrystalLLM::Capabilities` subclass (see provider_completion.cr for why
# Capabilities is a class hierarchy).
#
# DEFERRED (per task scope — CHAT path only):
# - Embeddings / Images / Transcription / (no Moderation on Gemini) provider
#   methods (gemini/{embeddings,images,transcription}.rb) are NOT ported.
# - Rich attachment / media formatting: only the text / Raw / Hash|Array content
#   paths chat needs are ported (gemini/media.cr). A Content carrying real
#   attachments raises a clear "deferred" error rather than silently dropping
#   them — the inline_data path depends on Attachment#encoded/#mime_type/#type,
#   part of the still-unported attachment-provider surface.
# - `build_response_content` (inline/file attachment reconstruction on the parse
#   side) is DEFERRED with the same attachment surface; parse_completion_response
#   collapses parts to joined text only.
# - Structured-output schema translation (GeminiSchema / convert_schema_to_gemini /
#   responseJsonSchema-vs-responseSchema version gate) is DEFERRED: it is a large
#   recursive JSON-schema rewriter and the chat-path tests don't exercise it. The
#   `schema:` hook is wired through render_payload to set responseMimeType +
#   responseSchema via a thin passthrough, with a documented divergence.
#
# Other divergences (see also the sub-files):
# - Crystal's `Message`/`Chunk` carry NO `thinking:` field yet (Message#thinking is
#   deferred — see message.cr); so parse_completion_response/build_chunk extract
#   text content + thinking_tokens but DROP thinking text/signature. Documented.
# - `tool_prefs:`/`toolConfig` (tool_choice) is deferred at the completion-pipeline
#   level (render_payload has no tool_prefs param — see provider_completion.cr);
#   `build_tool_config` is still ported for when the chat/agent layer wires it in.
# - `@model` (ruby_llm sets an ivar in render_payload that completion_url/stream_url
#   read) becomes an instance var `@model_id` set in render_payload; completion_url/
#   stream_url read it (raising if render_payload hasn't run — same coupling as Ruby).
# - SecureRandom.uuid -> UUID.random (stdlib `uuid`).
require "json"
require "uuid"
require "../provider"
require "../provider_completion"
require "../configuration"
require "../message"
require "../chunk"
require "../content"
require "../tool"
require "../tool_call"
require "../model/info"
require "../thinking"
require "../utils"

module CrystalLLM
  # Reopen Configuration to register Gemini's provider options (the Crystal analog
  # of ruby_llm's `register_provider_options` — each provider file adds typed
  # `property`s at compile time; see PORTING.md "register_provider_options pattern").
  class Configuration
    property gemini_api_key : String? = nil
    property gemini_api_base : String? = nil
  end

  module Providers
    # Native Gemini API integration (chat + tools + streaming).
    class Gemini < Provider
      # `@model_id` is set by `render_payload` (ruby_llm's `@model` ivar pattern);
      # `completion_url`/`stream_url` interpolate it into the path.
      @model_id : String? = nil

      def api_base : String
        @config.gemini_api_base || "https://generativelanguage.googleapis.com/v1beta"
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.gemini_api_key
          h["x-goog-api-key"] = key
        end
        h
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end

      def self.configuration_requirements : Array(String)
        ["gemini_api_key"]
      end

      def self.configuration_options : Array(String)
        %w[gemini_api_key gemini_api_base]
      end
    end
  end
end

require "./gemini/media"
require "./gemini/tools"
require "./gemini/chat"
require "./gemini/streaming"
require "./gemini/models"
require "./gemini/capabilities"
require "./gemini/embeddings"
require "./gemini/images"
require "./gemini/transcription"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('gemini', ...)`).
CrystalLLM::Provider.register("gemini", CrystalLLM::Providers::Gemini)
