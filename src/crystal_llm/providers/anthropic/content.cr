# ported from lib/ruby_llm/providers/anthropic/content.rb @ ruby_llm 1.15.0
#
# Helper for constructing Anthropic native content blocks. Builds a
# `CrystalLLM::Content::Raw` wrapping an array of Anthropic content-block hashes,
# optionally with `cache_control` set for prompt caching.
#
# Usage:
#   # Simple text block (no caching):
#   raw = Anthropic::Content.build("Some instructions")
#   # => Content::Raw wrapping [{type:"text", text:"Some instructions"}]
#
#   # With ephemeral cache_control:
#   raw = Anthropic::Content.build("Large document", cache: true)
#   # => Content::Raw wrapping [{type:"text", text:"...", cache_control:{type:"ephemeral"}}]
#
#   # With explicit cache_control object:
#   raw = Anthropic::Content.build("text", cache_control: JSON.parse(%({"type":"ephemeral"})))
#
#   # Pre-built parts array:
#   raw = Anthropic::Content.build(parts: [existing_block])
#
# Divergences from ruby_llm:
# - Ruby's `Anthropic::Content.new(...)` is a class-method override on a subclass
#   of Hash/Object. Crystal has no open-class `new` override; the static factory
#   method `Anthropic::Content.build(...)` is used instead.
# - Extra keyword arguments (`**extras`) in ruby_llm become an explicit
#   `extras : Hash(String, JSON::Any)?` parameter (Crystal has no arbitrary splat).
# - The `parts` parameter is `Array(JSON::Any)?` (ruby_llm uses `Array(Hash)`).
require "json"
require "../anthropic"

module CrystalLLM
  module Providers
    class Anthropic < Provider
      # Factory for Anthropic native content blocks (see file header).
      class Content
        # Builds a Content::Raw from either *text* (+ optional caching) or a
        # pre-built *parts* array. Mirrors ruby_llm's `Anthropic::Content.new`.
        def self.build(text : String? = nil,
                       cache : Bool = false,
                       cache_control : JSON::Any? = nil,
                       parts : Array(JSON::Any)? = nil,
                       extras : Hash(String, JSON::Any)? = nil) : CrystalLLM::Content::Raw
          payload = resolve_payload(
            text: text,
            parts: parts,
            cache: cache,
            cache_control: cache_control,
            extras: extras
          )
          CrystalLLM::Content::Raw.new(JSON::Any.new(payload))
        end

        private def self.resolve_payload(text : String?,
                                         parts : Array(JSON::Any)?,
                                         cache : Bool,
                                         cache_control : JSON::Any?,
                                         extras : Hash(String, JSON::Any)?) : Array(JSON::Any)
          return parts if parts

          raise ArgumentError.new("text or parts must be provided") if text.nil?

          block = {"type" => JSON::Any.new("text"), "text" => JSON::Any.new(text)} of String => JSON::Any
          if extra = extras
            extra.each { |k, v| block[k] = v }
          end

          control = determine_cache_control(cache_control, cache)
          block["cache_control"] = control if control

          [JSON::Any.new(block)]
        end

        private def self.determine_cache_control(cache_control : JSON::Any?,
                                                 cache_flag : Bool) : JSON::Any?
          return cache_control if cache_control

          if cache_flag
            JSON::Any.new({"type" => JSON::Any.new("ephemeral")} of String => JSON::Any)
          end
        end
      end
    end
  end
end
