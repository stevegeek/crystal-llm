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

      # DIVERGENCE-PARITY: ruby_llm's Azure::Media only handles image/audio/text
      # attachments and raises UnsupportedAttachmentError for :pdf/:document (the
      # `else` branch). Stock OpenAI::Media would happily send a PDF as a `file`
      # part, so Azure must gate documents OFF (`document_attachments: "none"`) to
      # reject both PDFs and non-PDF documents (docx, …). image + audio stay enabled.
      def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
        Media.format_content(
          content,
          document_attachments: "none",
          image_attachments: true,
          audio_attachments: true
        )
      end
    end
  end
end
