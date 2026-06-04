# ported from lib/ruby_llm/providers/bedrock*.rb @ ruby_llm 1.15.0
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
# - HARD AUTH: AWS SigV4 request signing (bedrock/auth.rb). ruby_llm's Bedrock signs
#   every request (signed_post/signed_get/sign_headers). The Crystal port implements
#   `headers` as a best-effort stub with an explicit 'auth deferred' note (see below)
#   and ports the SigV4 helper shape in bedrock/auth.cr behind `sign_headers` for when
#   the Connection layer wires per-request signing. No live calls are made in the spec,
#   so the unit surface (render_payload/parse_completion_response/build_chunk) is exact.
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
  # bedrock_region bedrock_session_token].
  class Configuration
    property bedrock_api_key : String? = nil
    property bedrock_secret_key : String? = nil
    property bedrock_region : String? = nil
    property bedrock_session_token : String? = nil
  end

  module Providers
    # AWS Bedrock Converse API integration.
    class Bedrock < Provider
      def api_base : String
        "https://bedrock-runtime.#{bedrock_region}.amazonaws.com"
      end

      # AUTH DEFERRED: ruby_llm returns `{}` here and signs each request separately
      # via the SigV4 helper (bedrock/auth.cr). Per-request signing is wired with the
      # Connection layer; until then `headers` is a best-effort stub returning the
      # JSON content-type. The SigV4 computation itself is ported in bedrock/auth.cr's
      # `sign_headers` so it is ready to slot in. Do NOT rely on this for live calls.
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
        %w[bedrock_api_key bedrock_secret_key bedrock_region bedrock_session_token]
      end

      # ruby_llm: `private def bedrock_region; @config.bedrock_region; end`.
      def bedrock_region : String?
        @config.bedrock_region
      end
    end
  end
end

require "./bedrock/auth"
require "./bedrock/chat"
require "./bedrock/streaming"
require "./bedrock/models"
require "./bedrock/capabilities"

# Register the provider (ruby_llm: `RubyLLM::Provider.register('bedrock', ...)`).
CrystalLLM::Provider.register("bedrock", CrystalLLM::Providers::Bedrock)
