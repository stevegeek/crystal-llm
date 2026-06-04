# ported from lib/ruby_llm/utils.rb @ ruby_llm 1.15.0
#
# Most of ruby_llm's Utils is Ruby-symbol/Hash plumbing that is a no-op or N/A in
# Crystal (deep_stringify_keys: JSON keys are already strings; deep_symbolize_keys /
# hash_get: no runtime symbols). Helpers are ported here as their first consumer
# arrives. `deep_merge` (used by Provider#complete to merge request params) is first.
require "json"

module CrystalLLM
  module Utils
    extend self

    # Recursively merges `overrides` into `original`; nested JSON objects merge,
    # scalars/arrays from `overrides` win. Operates on the wire shape (JSONData).
    def deep_merge(original : Hash(String, JSON::Any), overrides : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      result = original.dup
      overrides.each do |key, override_value|
        existing = result[key]?
        if existing && (existing_hash = existing.as_h?) && (override_hash = override_value.as_h?)
          result[key] = JSON::Any.new(deep_merge(existing_hash, override_hash))
        else
          result[key] = override_value
        end
      end
      result
    end
  end
end
