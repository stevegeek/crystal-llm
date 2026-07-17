# ported from lib/ruby_llm/model.rb @ ruby_llm 1.16.0
require "./model/modalities"
require "./model/pricing_tier"
require "./model/pricing_category"
require "./model/pricing"
require "./model/info"

module CrystalLLM
  # Model-related classes for working with LLM models.
  #
  # In ruby_llm this file is a bare namespace (`module Model; end`); the actual
  # classes live in `model/*.rb` and are required elsewhere. The port keeps the
  # namespace and additionally requires the `model/*` files so a single
  # `require "./model"` pulls in the whole subtree (Modalities, PricingTier,
  # PricingCategory, Pricing, Info).
  module Model
  end
end
