# ported from lib/ruby_llm/providers/gpustack/chat.rb @ ruby_llm 1.16.0
#
# Chat methods of the GPUStack API integration. Unlike OpenAI (which maps the system
# role to "developer"), GPUStack uses the bare lowercase role string for every role.
#
# Divergences from ruby_llm:
# - gpustack/chat.rb overrides `format_messages` to merge `OpenAI::Chat.format_thinking(msg)`
#   into each message, and (ruby_llm 1.16.0 / 7088339b) to swap in a `''` content for
#   a thinking-only assistant message via its own `format_message_content` wrapper.
#   Both are already covered by inheritance here: `format_messages`/`format_thinking`/
#   `format_message_content`/`thinking_only_assistant_message?` all live once in
#   openai/chat.cr (this port's providers are real subclasses, not Ruby's
#   module-`include`d duplicates — see openai/chat.cr's divergence note), and
#   `format_content` below is GPUStack's polymorphic override that
#   `format_message_content` dispatches to. Only `format_role` differs, so only it
#   is overridden.
require "json"
require "../gpustack"

module CrystalLLM
  module Providers
    class GPUStack < OpenAI
      # gpustack/chat.rb: `format_role(role) = role.to_s`. Unlike OpenAI (which maps
      # the system role to "developer"), GPUStack uses the bare lowercase role string.
      def format_role(role : Role) : String
        role.to_s.downcase
      end
    end
  end
end
