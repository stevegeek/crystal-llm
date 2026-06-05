# ported from lib/ruby_llm/providers/deepseek/chat.rb @ ruby_llm 1.15.0
#
# Chat overrides for DeepSeek. The bulk of the chat surface (render_payload,
# parse_completion_response, format_messages, token accounting) is inherited
# unchanged from Providers::OpenAI; only `format_role` differs.
#
# Divergences:
# - format_role: ruby_llm's DeepSeek returns `role.to_s` verbatim (no
#   system->developer remapping). The Crystal Role enum stringifies CamelCase
#   ("System"/"User"/...), so we `.downcase` to match the wire role names OpenAI's
#   non-system path also produces. openai_use_system_role plays no part here.
# - format_content: ruby_llm's DeepSeek strips ALL attachments
#   (document_attachments: :none, image_attachments: false, audio_attachments: false)
#   — DeepSeek is a text-only chat provider. We override `format_content` to pass that
#   gating to OpenAI::Media. document_attachments: "none" is not "all"/"pdf", so the
#   document strategy falls through and any document/pdf attachment raises
#   UnsupportedAttachmentError; image/audio raise via their disabled flags. Plain text
#   content passes through unchanged.
require "../openai"

module CrystalLLM
  module Providers
    class DeepSeek < OpenAI
      def format_role(role : Role) : String
        role.to_s.downcase
      end

      # DeepSeek is text-only: every attachment kind is gated off.
      def format_content(content : String | Content | Content::Raw | Nil) : JSON::Any
        Media.format_content(
          content,
          document_attachments: "none",
          image_attachments: false,
          audio_attachments: false
        )
      end
    end
  end
end
