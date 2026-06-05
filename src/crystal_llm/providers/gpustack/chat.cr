# ported from lib/ruby_llm/providers/gpustack/chat.rb @ ruby_llm 1.15.0
#
# Chat methods of the GPUStack API integration. Unlike OpenAI (which maps the system
# role to "developer"), GPUStack uses the bare lowercase role string for every role.
#
# Divergences from ruby_llm:
# - gpustack/chat.rb overrides `format_messages` to merge `OpenAI::Chat.format_thinking(msg)`
#   into each message; the Crystal OpenAI port does NOT port format_thinking (Message#
#   thinking extraction is deferred — see openai/chat.cr), so the inherited
#   format_messages omits it too and is not re-declared here. Only `format_role` differs,
#   so only it is overridden (the rest of format_messages is inherited from OpenAI).
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
