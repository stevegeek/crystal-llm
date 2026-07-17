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
# Scope notes:
# - Embeddings / Images / Transcription provider methods (no Moderation on Gemini)
#   ARE ported — see gemini/{embeddings,images,transcription}.cr (they feed the
#   provider_media.cr pipeline).
# - Rich attachment / media formatting IS ported (gemini/media.cr): binary
#   attachments (image/audio/pdf/video) become `inline_data` parts, text-files
#   inline as text, document/unknown raise UnsupportedAttachmentError.
# - `build_response_content` (inline/file attachment reconstruction on the parse
#   side) IS PORTED: gemini/inbound_media.cr adds build_response_content /
#   build_inline_attachment / build_file_attachment / attachment_filename.
# PORTED (2026-06-05): Structured-output schema translation. The recursive
# GeminiSchema rewriter (uppercase TYPE values, propertyOrdering, nullable, anyOf
# collapse, $ref/$defs resolution-or-strip) plus the responseJsonSchema-vs-
# responseSchema version gate now live in gemini/schema.cr (Providers::GeminiSchema),
# SHARED with VertexAI. render_payload's `structured_output_config` delegates to it.
#
# Other divergences (see also the sub-files):
# - Message#thinking IS wired: parse_completion_response/build_chunk extract thought
#   parts + thoughtSignature into `Thinking.build` (see gemini/chat.cr,
#   gemini/streaming.cr), alongside thinking_tokens.
# - `tool_prefs:`/`toolConfig` (tool_choice) IS emitted by render_payload: when
#   `choice` is set it builds `toolConfig.functionCallingConfig` via
#   `build_tool_config(choice)` (see gemini/chat.cr).
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

require "./gemini/schema"
require "./gemini/media"
require "./gemini/inbound_media"
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
