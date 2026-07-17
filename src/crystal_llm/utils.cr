# ported from lib/ruby_llm/utils.rb @ ruby_llm 1.16.0
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
    #
    # Neither argument is mutated, and — crucially — the returned hash shares NO
    # mutable nested hash object with either input. `Hash#dup` is SHALLOW: a bare
    # `original.dup` leaves the result's untouched nested branches aliasing
    # `original`'s own nested hashes, so a later in-place mutation of the result
    # would silently corrupt `original` (and vice-versa for `overrides`). We deep-dup
    # the nested-object values we carry over instead.
    def deep_merge(original : Hash(String, JSON::Any), overrides : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      original.each { |key, value| result[key] = deep_dup(value) }
      overrides.each do |key, override_value|
        existing = result[key]?
        if existing && (existing_hash = existing.as_h?) && (override_hash = override_value.as_h?)
          result[key] = JSON::Any.new(deep_merge(existing_hash, override_hash))
        else
          result[key] = deep_dup(override_value)
        end
      end
      result
    end

    # Recursively copies a `JSON::Any` so the copy shares no mutable Hash/Array with
    # the source (scalars are immutable and returned as-is). Keeps `deep_merge`'s
    # output fully detached from its inputs.
    private def deep_dup(value : JSON::Any) : JSON::Any
      if hash = value.as_h?
        copy = {} of String => JSON::Any
        hash.each { |k, v| copy[k] = deep_dup(v) }
        JSON::Any.new(copy)
      elsif array = value.as_a?
        JSON::Any.new(array.map { |v| deep_dup(v) })
      else
        value
      end
    end

    # Parses ISO date prefixes (YYYY-MM-DD, YYYY-MM, YYYY) into Time objects.
    # Returns a Time in UTC: full dates parse as-is, YYYY-MM expands to the first
    # of the month, YYYY expands to January 1. Returns nil for blank or malformed input.
    #
    # Note: ruby_llm returns Date; the Crystal port's established date type is Time (UTC).
    def parse_iso_date_prefix(value : String | Time | Nil) : Time?
      return value if value.is_a?(Time)
      date = value.to_s.strip
      return nil if date.empty?

      begin
        case date
        when /\A\d{4}-\d{2}-\d{2}\z/ then Time.parse_utc(date, "%Y-%m-%d")
        when /\A\d{4}-\d{2}\z/       then Time.parse_utc("#{date}-01", "%Y-%m-%d")
        when /\A\d{4}\z/             then Time.parse_utc("#{date}-01-01", "%Y-%m-%d")
        end
      rescue Time::Format::Error | ArgumentError
        nil
      end
    end

    # Renders an ISO date prefix as a UTC midnight string: "YYYY-MM-DD 00:00:00 UTC".
    # Returns nil when the date does not parse.
    def iso_date_prefix_to_utc_midnight_string(value : String | Time | Nil) : String?
      parse_iso_date_prefix(value).try { |date| "#{date.to_s("%Y-%m-%d")} 00:00:00 UTC" }
    end
  end
end
