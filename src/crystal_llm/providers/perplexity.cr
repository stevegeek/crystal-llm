# ported from lib/ruby_llm/providers/perplexity.rb (+ perplexity/{chat,models,capabilities,media}.rb) @ ruby_llm 1.15.0
#
# Perplexity (Sonar) is an OpenAI-compatible chat provider. ruby_llm models it as
# `Perplexity < OpenAI` including Perplexity::{Chat,Models}; the Crystal port keeps
# that shape — `Providers::Perplexity < Providers::OpenAI` reopened in sections
# (perplexity/{chat,models,capabilities}.cr) and inheriting everything else from
# OpenAI (render_payload, parse_completion_response, build_chunk, tools, streaming,
# temperature, the token accounting). Only what genuinely differs is overridden:
# api_base, headers, configuration_requirements/options, capabilities, the static
# model list, and the HTML-aware parse_error.
#
# DEFERRED (per task scope — CHAT path only):
# - Embeddings / image / moderation / transcription provider methods: Perplexity
#   inherits none of those from OpenAI's deferred set; nothing extra to port.
# - Attachment media formatting (perplexity/media.rb — format_document / file_url
#   parts / SUPPORTED_DOCUMENT_EXTENSIONS / format_text_attachment): DEFERRED with
#   the attachment-provider work, exactly as OpenAI's media.cr defers its rich
#   attachment paths. A Content carrying attachments raises the inherited
#   "deferred" error rather than silently dropping them. The text/Raw/Hash content
#   paths chat needs are inherited from OpenAI::Media.
#
# Divergences:
# - format_messages: ruby_llm's Perplexity::Chat#format_messages re-implements the
#   OpenAI message map only to splice in `format_content` (its media variant) plus
#   `OpenAI::Chat.format_thinking`. Message#thinking and rich attachment formatting
#   are BOTH deferred in this port (see message.cr / openai/media.cr), so the
#   re-implementation would be byte-identical to the inherited OpenAI#format_messages
#   for the in-scope (text) path. We therefore inherit OpenAI#format_messages rather
#   than copy it — same wire output, less drift. Documented + returned as a divergence.
# - format_role: ruby_llm's Perplexity::Chat#format_role is `role.to_s` (no
#   system->developer remap; Perplexity has no developer role). Overridden here to
#   the plain downcased role string (OpenAI's remap keys off openai_use_system_role,
#   which Perplexity never sets).
require "json"
require "./openai"
require "../provider"
require "../provider_completion"
require "../configuration"
require "../message"
require "../model/info"

module CrystalLLM
  # Reopen Configuration to register Perplexity's provider options (the Crystal
  # analog of ruby_llm's `register_provider_options` — each provider file adds typed
  # `property`s at compile time; see PORTING.md "register_provider_options pattern").
  class Configuration
    property perplexity_api_key : String? = nil
  end

  module Providers
    # Perplexity (Sonar) API integration — OpenAI-compatible chat. See file header.
    class Perplexity < OpenAI
      def api_base : String
        "https://api.perplexity.ai"
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.perplexity_api_key
          h["Authorization"] = "Bearer #{key}"
        end
        h["Content-Type"] = "application/json"
        h
      end

      # ruby_llm Perplexity::Chat#format_role: plain `role.to_s` (no developer remap).
      def format_role(role : Role) : String
        role.to_s.downcase
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end

      def self.configuration_requirements : Array(String)
        ["perplexity_api_key"]
      end

      def self.configuration_options : Array(String)
        ["perplexity_api_key"]
      end

      # Perplexity returns HTML (not JSON) for auth errors; pull the <title> text and
      # strip a leading status code, else fall back to the JSON-aware base extractor.
      def parse_error(response : Crest::Response) : String?
        body = response.body
        return nil if body.empty?

        if body.includes?("<html>") && body.includes?("<title>")
          if match = body.match(/<title>(.+?)<\/title>/)
            message = match[1]
            return message.sub(/^\d+\s+/, "")
          end
        end

        super
      end
    end
  end
end

require "./perplexity/capabilities"
require "./perplexity/models"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('perplexity', ...)`).
CrystalLLM::Provider.register("perplexity", CrystalLLM::Providers::Perplexity)
