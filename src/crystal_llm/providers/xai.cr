# ported from lib/ruby_llm/providers/xai.rb (+ xai/{chat,models}.rb) @ ruby_llm 1.16.0
#
# xAI (Grok) API integration. xAI is OpenAI-compatible, so this subclasses
# Providers::OpenAI and overrides only what differs:
#   - api_base       -> https://api.x.ai/v1
#   - headers        -> Bearer #{xai_api_key} (xAI's own key, no org/project headers)
#   - configuration_{requirements,options} -> ["xai_api_key"]
#   - format_role    -> always `role.to_s.downcase` (NO system->developer swap that
#                       OpenAI does; xAI keeps the "system" role)
#   - parse_list_models_response -> xAI's own model metadata (family "grok",
#                       vision/reasoning/image families, modalities + capabilities)
#
# Everything else (completion_url, stream_url, render_payload, parse_completion_response,
# build_chunk, format_messages, models_url, tool serialization, token accounting) is
# inherited verbatim from Providers::OpenAI — the request/response wire shape is
# identical.
#
# DEFERRALS (per task scope — CHAT path only):
#   - embeddings / image-generation / moderation / transcription provider methods:
#     xAI inherits none of those here (they are deferred on the OpenAI base too).
#   - Attachment media formatting: ruby_llm's XAI::Chat#format_content restricts
#     attachments to images only (document_attachments: :none, image: true,
#     audio: false). This is now ported via the `format_content` override below
#     (vision parity): image attachments format normally; document/pdf and audio
#     attachments raise UnsupportedAttachmentError.
#   - Hard auth (real network calls) is out of scope; this is unit-tested in isolation.
#
# DIVERGENCES:
#   - Capabilities: ruby_llm's XAI::Models bakes per-model capability/modality logic
#     directly into parse_list_models_response rather than a Capabilities helper.
#     The Crystal port keeps that inline (Models#modalities_for / #capabilities_for
#     translated to instance helpers on the provider) — it does NOT route through
#     the OpenAI Capabilities class for the model list. `self.capabilities` still
#     returns the OpenAI Capabilities subclass (inherited) for the abstract hook, but
#     parse_list_models_response ignores it (matching ruby_llm, which passes
#     `_capabilities`). Documented + returned as a divergence.
#   - Time.at(created) -> Time.unix(created); response.body is a raw String (Crest)
#     so we JSON.parse it in-method (ruby_llm's Faraday pre-parses).
require "json"
require "./openai"

module CrystalLLM
  # Reopen Configuration to register xAI's provider option (the Crystal analog of
  # ruby_llm's `register_provider_options` — each provider file adds typed
  # `property`s at compile time; see PORTING.md "register_provider_options pattern").
  class Configuration
    nilable_string_option xai_api_key
    # ruby_llm bf152ec8: lets a proxy/gateway/private endpoint stand in for the
    # default xAI host (consulted by `api_base` below).
    nilable_string_option xai_api_base
  end

  module Providers
    # xAI (Grok) API integration — OpenAI-compatible (see file header).
    class XAI < OpenAI
      def api_base : String
        @config.xai_api_base || "https://api.x.ai/v1"
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.xai_api_key
          h["Authorization"] = "Bearer #{key}"
        end
        h["Content-Type"] = "application/json"
        h
      end

      # xAI keeps the "system" role as-is (unlike OpenAI, which may swap it to
      # "developer"). ruby_llm: XAI::Chat#format_role(role) => role.to_s.
      def format_role(role : Role) : String
        role.to_s.downcase
      end

      # xAI accepts image attachments but not documents or audio.
      # ruby_llm: XAI::Chat#format_content(content,
      #   document_attachments: :none, image_attachments: true, audio_attachments: false).
      def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
        Media.format_content(
          content,
          document_attachments: "none",
          image_attachments: true,
          audio_attachments: false
        )
      end

      def self.configuration_requirements : Array(String)
        ["xai_api_key"]
      end

      def self.configuration_options : Array(String)
        %w[xai_api_key xai_api_base]
      end
    end
  end
end

require "./xai/models"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('xai', ...)`).
CrystalLLM::Provider.register("xai", CrystalLLM::Providers::XAI)
