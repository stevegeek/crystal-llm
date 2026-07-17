# ported from lib/ruby_llm/moderation.rb @ ruby_llm 1.16.0
require "json"

module CrystalLLM
  # Identify potentially harmful content in text.
  # https://platform.openai.com/docs/guides/moderation
  #
  # This is the immutable DATA object returned by a moderation request. Each entry
  # in `results` is one provider result object (the OpenAI moderation API returns
  # an array under `"results"`), carried verbatim as `JSON::Any`.
  #
  # == Divergences from ruby_llm (documented, idiomatic Crystal) ==
  #
  # * Wire data is `JSON::Any`, per the port's convention (PORTING.md / design §11):
  #   `results` is `Array(JSON::Any)` rather than an `Array` of Ruby Hashes. The
  #   convenience accessors therefore index with `["key"]?` and read `.as_bool`/
  #   `.as_h` off `JSON::Any` instead of Ruby's duck-typed `result['flagged']`.
  # * `categories` / `category_scores` return `Hash(String, JSON::Any)` (the empty
  #   case is an empty hash), mirroring ruby_llm's `{}` default.
  #
  # == Class-method entry point (lives in provider_media.cr) ==
  #
  # * `Moderation.moderate(input, ...)` — the class-method entry point (it resolves
  #   the model via `Models.resolve` and dispatches to a Provider's `#moderate`)
  #   lives in `provider_media.cr`, alongside the moderate pipeline. The top-level
  #   `CrystalLLM.moderate` facade shim lives there too.
  class Moderation
    getter id : String
    getter model : String
    # Each element is one provider result object (a JSON object).
    getter results : Array(JSON::Any)

    def initialize(@id : String, @model : String, @results : Array(JSON::Any))
    end

    # Convenience method to get content from a moderation result. Mirrors
    # ruby_llm's `#content`, which simply returns `results`.
    def content : Array(JSON::Any)
      results
    end

    # Check if any content was flagged.
    # ruby_llm: `results.any? { |result| result['flagged'] }`.
    def flagged? : Bool
      results.any? do |result|
        flag = result["flagged"]?
        flag ? flag.as_bool? == true : false
      end
    end

    # Get all flagged categories across all results.
    # ruby_llm: flat_map over each result's truthy `categories`, uniq'd.
    def flagged_categories : Array(String)
      results.flat_map do |result|
        cats = result["categories"]?.try(&.as_h?)
        if cats
          cats.select { |_category, flagged| flagged.as_bool? == true }.keys
        else
          [] of String
        end
      end.uniq!
    end

    # Get category scores for the first result (most common case).
    # ruby_llm: `results.first&.dig('category_scores') || {}`.
    def category_scores : Hash(String, JSON::Any)
      first = results.first?
      return empty_object unless first

      first["category_scores"]?.try(&.as_h?) || empty_object
    end

    # Get categories for the first result (most common case).
    # ruby_llm: `results.first&.dig('categories') || {}`.
    def categories : Hash(String, JSON::Any)
      first = results.first?
      return empty_object unless first

      first["categories"]?.try(&.as_h?) || empty_object
    end

    private def empty_object : Hash(String, JSON::Any)
      {} of String => JSON::Any
    end
  end
end
