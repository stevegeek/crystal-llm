# ported from lib/ruby_llm/providers/deepseek.rb (+ deepseek/{chat,capabilities}.rb) @ ruby_llm 1.16.0
#
# DeepSeek API integration. DeepSeek is OpenAI-compatible, so the Crystal port
# subclasses Providers::OpenAI and overrides only what differs: api_base, headers,
# configuration_requirements/options, capabilities, and the chat `format_role`
# (DeepSeek uses a plain lowercased role, never OpenAI's system->developer mapping).
# Everything else (render_payload, parse_completion_response, build_chunk,
# format_messages, models_url, parse_list_models_response, completion_url,
# stream_url, token accounting) is inherited unchanged from OpenAI.
#
# DEFERRED (per task scope — CHAT path only): the embeddings/image/moderation/
# transcription provider methods are inherited-but-not-ported on OpenAI itself
# (see openai.cr header) and are likewise out of scope here. Rich attachment media
# formatting is deferred with the attachment-provider work; ruby_llm's DeepSeek
# Chat#format_content additionally STRIPS all attachments (document_attachments:
# :none, image/audio false). For the chat text-only scope ported here the OpenAI
# text path already passes bare String content through; the attachment-stripping
# behavior is noted as a divergence (see deepseek/chat.cr) and reproduced once the
# attachment surface lands.
#
# Divergences:
# - api_base has NO `/v1` suffix (ruby_llm: 'https://api.deepseek.com').
# - headers carry only Authorization (no Organization/Project headers).
# - format_role: plain `role.to_s.downcase` (DeepSeek has no system->developer
#   remapping; openai_use_system_role is irrelevant here).
require "json"
require "./openai"

module CrystalLLM
  # Reopen Configuration to register DeepSeek's provider options (the Crystal analog
  # of ruby_llm's `register_provider_options` — see PORTING.md). Parallel-safe: this
  # provider adds only its own typed `property`s.
  class Configuration
    nilable_string_option deepseek_api_key
    nilable_string_option deepseek_api_base
  end

  module Providers
    # DeepSeek API integration (OpenAI-compatible chat + tools + streaming).
    class DeepSeek < OpenAI
      def api_base : String
        @config.deepseek_api_base || "https://api.deepseek.com"
      end

      def headers : Hash(String, String)
        h = {} of String => String
        if key = @config.deepseek_api_key
          h["Authorization"] = "Bearer #{key}"
        end
        h
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end

      def self.configuration_requirements : Array(String)
        ["deepseek_api_key"]
      end

      def self.configuration_options : Array(String)
        %w[deepseek_api_key deepseek_api_base]
      end
    end
  end
end

require "./deepseek/capabilities"
require "./deepseek/chat"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('deepseek', ...)`).
CrystalLLM::Provider.register("deepseek", CrystalLLM::Providers::DeepSeek)
