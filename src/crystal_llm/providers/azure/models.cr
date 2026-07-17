# ported from lib/ruby_llm/providers/azure/models.rb @ ruby_llm 1.16.0
#
# Azure list-models URL override. Routes through `azure_endpoint("models")` (the
# openai/v1 models path or the resource-base `/openai/v1/models?api-version=...`
# URL). The response parsing + Model::Info building are inherited unchanged from
# OpenAI::parse_list_models_response (Azure returns the same shape).
require "json"
require "../azure"

module CrystalLLM
  module Providers
    class Azure < OpenAI
      def models_url : String
        azure_endpoint("models")
      end
    end
  end
end
