# ported from lib/ruby_llm/providers/azure/chat.rb @ ruby_llm 1.15.0
#
# Azure chat URL + message formatting overrides. Azure routes chat completions
# through `azure_endpoint("chat")` (deployment/resource/v1 detection) and emits the
# message `role` verbatim (no OpenAI system->developer remap).
#
# Divergences:
# - format_messages reuses OpenAI's content/tool_call formatting but overrides
#   format_role to be the plain lowercased role (ruby_llm Azure::Chat#format_role
#   `role.to_s`). OpenAI's render_payload/parse_completion_response/token accounting
#   are inherited unchanged.
# - stream_url inherits OpenAI's (= completion_url), which here resolves to the
#   Azure chat endpoint.
require "json"
require "../azure"

module CrystalLLM
  module Providers
    class Azure < OpenAI
      def completion_url : String
        azure_endpoint("chat")
      end

      # Azure emits the role string verbatim (no system->developer remap that stock
      # OpenAI applies). Mirrors ruby_llm Azure::Chat#format_role.
      def format_role(role : Role) : String
        role.to_s.downcase
      end

      # Azure attachment policy: images and audio are allowed; PDF and other
      # documents are NOT supported (raise UnsupportedAttachmentError).
      # Azure::Media#format_content implements this policy directly — delegate to it.
      # (Overrides the inherited OpenAI::Media delegation; Media here is Azure::Media.)
      def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
        Media.format_content(content)
      end
    end
  end
end
