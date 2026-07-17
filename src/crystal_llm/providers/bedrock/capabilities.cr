# ported from lib/ruby_llm/providers/bedrock/models.rb (the capability predicates) @ ruby_llm 1.16.0
#
# Bedrock derives most capabilities/pricing from the live `/foundation-models`
# summary rows (see models.cr#parse_capabilities), not a static registry. So this
# Capabilities subclass is thin: the base conservative answers suffice for the
# `parse_list_models_response(capabilities)` argument, and the only behaviorally
# meaningful method is `reasoning_embedded?` (read by chat.cr's reasoning config and
# by the upstream `model_supports_top_k?` normalization).
#
# Divergence: ruby_llm's `reasoning_embedded?` deep-symbolizes `model.metadata`; here
# the metadata is `Hash(String, JSON::Any)` (string keys, camelCase preserved), so we
# read `converse.reasoningSupported.embedded` directly.
require "json"
require "../bedrock"

module CrystalLLM
  module Providers
    class Bedrock < Provider
      class Capabilities < CrystalLLM::Capabilities
        # True when the model's converse metadata advertises embedded reasoning.
        def self.reasoning_embedded?(model : Model::Info) : Bool
          converse = model.metadata["converse"]?.try(&.as_h?)
          return false unless converse

          embedded = converse.dig?("reasoningSupported", "embedded")
          return false if embedded.nil?
          embedded.as_bool? || false
        end
      end
    end
  end
end
