# ported from lib/ruby_llm/providers/bedrock*.rb @ ruby_llm 1.16.0
#
# AWS Bedrock Converse API integration (chat + tools + streaming + models).
#
# ruby_llm splits Bedrock into Auth/Chat/Media/Models/Streaming `module_function`
# mixins included into one `Bedrock < Provider` class. The Crystal port collapses
# them into one class reopened across sub-files (bedrock/{chat,streaming,models,
# capabilities,auth}.cr), mirroring the OpenAI port.
#
# DEFERRED (per task scope):
# - Non-chat provider methods (embeddings/image/moderation/transcription) — Bedrock
#   never ported them in ruby_llm either; nothing to do.
# - Rich attachment media formatting (image/document/text blocks in bedrock/media.rb)
#   is DEFERRED with the attachment-provider work — the text/Hash/Array content paths
#   chat needs are ported inline in chat.cr's render_message_content. See the note there.
# - AWS SigV4 request signing (bedrock/auth.rb) is WIRED. ruby_llm's Bedrock signs
#   every request (signed_post/signed_get/sign_headers). The Crystal port overrides the
#   `Provider#sign_headers(method, url, body)` hook in bedrock/auth.cr (computing SigV4
#   via the awscr-signer shard) and the sync/stream/list pipeline merges those headers
#   into every request. Specs assert the signed-header shape structurally — NO live AWS.
#
# NOT PORTED (tracked gaps — re-port candidates if a need surfaces):
# - `normalize_params` + `model_supports_top_k?` (ruby_llm Bedrock::Chat): ruby_llm
#   strips a `top_k` param for models that don't support it before merging into the
#   Converse payload. The Crystal port has no top_k param plumbing, so nothing to
#   normalize yet — re-port alongside arbitrary-param passthrough if added.
# - Bedrock-specific `parse_error` (ruby_llm Bedrock overrides it to dig the AWS
#   `message`/`Message` envelope): the port uses the base `Provider#parse_error`
#   (OpenAI-shaped `error.message`), which does NOT match Bedrock's error body. A
#   Bedrock error currently falls through to the raw body. Re-port if precise Bedrock
#   error messages are needed.
#
# Other divergences (documented at each hook):
# - `@model` instance state: ruby_llm stashes `@model` in render_payload and reads it
#   in completion_url/stream_url/effort config. The port threads the model through the
#   hook arguments where the frozen interface allows, and keeps a `@current_model`
#   ivar for the URL hooks (which take no model arg in the frozen interface).
# - `tool_prefs`/`thinking` text extraction onto Message are deferred (Message#thinking
#   is itself deferred — see message.cr). Token-level reasoning_tokens ARE wired.
# - Bedrock ToolCall ids/names are non-nil in CrystalLLM's ToolCall; the streaming
#   `nil`-keyed partial deltas (ruby_llm) become empty-string keys here (the stream
#   accumulator merges by buffer position — same convention as OpenAI streaming).
require "json"
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
  # Reopen Configuration to register Bedrock's provider options (the Crystal analog
  # of ruby_llm's `register_provider_options` — each provider file adds typed
  # `property`s at compile time; see PORTING.md "register_provider_options pattern").
  #
  # ruby_llm: configuration_options = %i[bedrock_api_key bedrock_secret_key
  # bedrock_region bedrock_session_token bedrock_api_base] (bf152ec8 adds the last one).
  class Configuration
    nilable_string_option bedrock_api_key
    nilable_string_option bedrock_secret_key
    nilable_string_option bedrock_region
    nilable_string_option bedrock_session_token
    # ruby_llm bf152ec8: overrides both the runtime host (`api_base` below) and the
    # control-plane host (`models_api_base`, bedrock/models.cr) with the same value.
    nilable_string_option bedrock_api_base
  end

  module Providers
    # AWS Bedrock Converse API integration.
    class Bedrock < Provider
      def api_base : String
        @config.bedrock_api_base || "https://bedrock-runtime.#{bedrock_region}.amazonaws.com"
      end

      # ruby_llm returns `{}` here and signs each request separately via the SigV4
      # helper. The Crystal port wires per-request signing through `sign_headers`
      # (bedrock/auth.cr), which is merged into every request by the sync/stream/list
      # pipeline and supplies the `Authorization`/`X-Amz-*` + `Content-Type` headers.
      # This static hash just sets the JSON content-type as a baseline (the signed
      # headers re-assert it); it carries no credentials.
      def headers : Hash(String, String)
        {"Content-Type" => "application/json"}
      end

      def self.capabilities : CrystalLLM::Capabilities.class
        Capabilities
      end

      def self.configuration_requirements : Array(String)
        ["bedrock_api_key", "bedrock_secret_key", "bedrock_region"]
      end

      def self.configuration_options : Array(String)
        %w[bedrock_api_key bedrock_secret_key bedrock_region bedrock_session_token bedrock_api_base]
      end

      # ruby_llm: `private def bedrock_region; @config.bedrock_region; end`.
      def bedrock_region : String?
        @config.bedrock_region
      end
    end
  end
end

require "./bedrock/auth"
require "./bedrock/media"
require "./bedrock/chat"
require "./bedrock/streaming"
require "./bedrock/models"
require "./bedrock/capabilities"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('bedrock', ...)`).
CrystalLLM::Provider.register("bedrock", CrystalLLM::Providers::Bedrock)
