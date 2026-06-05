# ported from lib/ruby_llm/providers/openrouter*.rb @ ruby_llm 1.15.0
#
# OpenRouter chat provider: text chat + tools + streaming + models.
# OpenRouter is an OpenAI-compatible aggregator, so this subclasses
# `CrystalLLM::Providers::OpenAI` and overrides only what differs:
#   - api_base / headers / configuration (openrouter_api_key, openrouter_api_base)
#   - render_payload: OpenRouter uses a `reasoning` object (not OpenAI's
#     `reasoning_effort` string) for thinking config (see openrouter/chat.cr).
#   - models_url + parse_list_models_response: OpenRouter's `/models` returns a far
#     richer per-model record (architecture modalities, pricing, supported_parameters)
#     than OpenAI's, with provider-supplied capabilities derived from each model's
#     `supported_parameters` (a private models.cr helper — see openrouter/models.cr).
#     The provider's `capabilities` class is inherited from OpenAI (ruby_llm's
#     OpenRouter likewise ships no Capabilities class).
# Everything else (completion_url, format_messages, format_role, parse_completion_response,
# token accounting, tool (de)serialization, build_chunk, parse_error) is inherited
# unchanged from OpenAI — the wire shapes are identical.
#
# DEFERRED (per task scope — CHAT path only): the OpenRouter::Images mixin
# (paint/render_image/parse_image) is NOT ported; embeddings/moderation/transcription
# are inherited-but-unported from OpenAI; rich attachment media formatting is deferred
# with OpenAI's media.cr. Thinking text/signature *extraction* into Message/Chunk is
# deferred (Message#thinking deferred — same as OpenAI); reasoning_tokens ARE wired.
# OpenRouter's `parse_error` "raw metadata" enrichment is also deferred (Provider's
# base parse_error + OpenAI's behavior cover the common case); see chat.cr note.
require "json"
require "./openai"

module CrystalLLM
  # Reopen Configuration to register OpenRouter's provider options (the Crystal
  # analog of ruby_llm's `register_provider_options`; see PORTING.md). Each provider
  # file adds its typed `property`s at compile time (parallel-safe).
  class Configuration
    property openrouter_api_key : String? = nil
    property openrouter_api_base : String? = nil
  end

  module Providers
    # OpenRouter API integration (chat + tools + streaming + models). Subclass of
    # OpenAI (OpenAI-compatible wire format); see file header for what differs.
    class OpenRouter < OpenAI
      def api_base : String
        @config.openrouter_api_base || "https://openrouter.ai/api/v1"
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.openrouter_api_key
          h["Authorization"] = "Bearer #{key}"
        end
        h
      end

      def self.configuration_requirements : Array(String)
        ["openrouter_api_key"]
      end

      def self.configuration_options : Array(String)
        %w[openrouter_api_key openrouter_api_base]
      end
    end
  end
end

require "./openrouter/chat"
require "./openrouter/models"
require "./openrouter/images"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('openrouter', ...)`).
CrystalLLM::Provider.register("openrouter", CrystalLLM::Providers::OpenRouter)
