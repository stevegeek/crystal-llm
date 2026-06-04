# ported from lib/ruby_llm/providers/perplexity/models.rb @ ruby_llm 1.15.0
#
# Perplexity has no list-models endpoint; the model set is a static MODEL_IDS list
# enriched from Capabilities.
#
# Divergences:
# - models_url: ruby_llm overrides `list_models` to skip the HTTP call entirely and
#   call `parse_list_models_response(nil, slug, Capabilities)`. The Crystal completion
#   pipeline's `list_models` always does `connection.get(models_url)` then passes the
#   response to `parse_list_models_response`. To stay on the frozen pipeline without
#   editing it, `models_url` returns "models" (a harmless path) and
#   `parse_list_models_response` IGNORES its `response` argument, returning the static
#   list — so the response body is never consulted. (ruby_llm's call is fully offline;
#   this port still issues the GET. Documented + returned as a divergence; a future
#   `list_models` override could drop the request, but that's outside frozen-interface
#   scope.)
# - Model::Info is built via `.build` (the keyword native-value constructor); pricing
#   arrives as a `Hash(String, JSON::Any)` and is wrapped in Pricing — matching
#   OpenAI::Models.
require "json"
require "../perplexity"
require "../../model/info"

module CrystalLLM
  module Providers
    class Perplexity < OpenAI
      MODEL_IDS = %w[
        sonar
        sonar-pro
        sonar-reasoning
        sonar-reasoning-pro
        sonar-deep-research
      ]

      def models_url : String
        "models"
      end

      # Ignores `response` (Perplexity's model set is static — see file header).
      def parse_list_models_response(response : Crest::Response, slug : String,
                                     capabilities : CrystalLLM::Capabilities.class) : Array(Model::Info)
        MODEL_IDS.map { |id| create_model_info(id, slug, capabilities) }
      end

      private def create_model_info(id : String, slug : String,
                                    capabilities : CrystalLLM::Capabilities.class) : Model::Info
        Model::Info.build(
          id: id,
          name: id,
          provider: slug,
          context_window: capabilities.context_window_for(id),
          max_output_tokens: capabilities.max_tokens_for(id),
          capabilities: capabilities.critical_capabilities_for(id),
          pricing: Model::Pricing.new(capabilities.pricing_for(id)),
          metadata: {} of String => JSON::Any
        )
      end
    end
  end
end
