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
# - format_content: ruby_llm's DeepSeek strips ALL attachments (document_attachments:
#   :none, image/audio false). For the chat text-only scope, the inherited OpenAI
#   text path already passes bare String content through; reproducing the explicit
#   attachment-stripping is DEFERRED with the attachment-provider work.
require "../openai"

module CrystalLLM
  module Providers
    class DeepSeek < OpenAI
      def format_role(role : Role) : String
        role.to_s.downcase
      end
    end
  end
end
