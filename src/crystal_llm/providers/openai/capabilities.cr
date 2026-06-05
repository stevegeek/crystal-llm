# ported from lib/ruby_llm/providers/openai/capabilities.rb @ ruby_llm 1.15.0
#
# Provider-level capability checks and narrow registry fallbacks (used by
# `parse_list_models_response`).
#
# Divergences:
# - ruby_llm's `Capabilities` is a `module_function` module; the Crystal port is a
#   `CrystalLLM::Capabilities` subclass (so a provider's `capabilities` can be passed
#   around as a class — see provider_completion.cr).
# - `PRICES` symbol-keyed family hashes -> a String-keyed lookup built in `family_prices`.
# - `pricing_for` returns the wire `Hash(String, JSON::Any)` shape Model::Pricing
#   consumes (`{"text_tokens" => {"standard" => {"input_per_million" => ...}}}`).
# - Image pricing (gpt-image families) is DEFERRED with the image-provider work; the
#   image families are treated as having no special pricing here (chat-only scope).
require "json"
require "../openai"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      # OpenAI capability + narrow-pricing helper (see file header for divergences).
      class Capabilities < CrystalLLM::Capabilities
        # ordered list mirroring ruby_llm's MODEL_PATTERNS (chat-relevant subset +
        # the families needed for NIL_LIMIT / pricing decisions).
        MODEL_PATTERNS = [
          {"gpt_image15", /^gpt-image-1\.5/},
          {"gpt_image_mini", /^gpt-image-1-mini/},
          {"gpt_image", /^gpt-image-1(?:$|-)/},
          {"gpt41", /^gpt-4\.1(?!-(?:mini|nano))/},
          {"gpt41_mini", /^gpt-4\.1-mini/},
          {"gpt41_nano", /^gpt-4\.1-nano/},
          {"gpt4", /^gpt-4(?:-\d{6})?$/},
          {"gpt4_turbo", /^gpt-4(?:\.5)?-(?:\d{6}-)?(preview|turbo)/},
          {"gpt35_turbo", /^gpt-3\.5-turbo/},
          {"gpt4o", /^gpt-4o(?!-(?:mini|audio|realtime|transcribe|tts|search))/},
          {"gpt4o_audio", /^gpt-4o-(?:audio)/},
          {"gpt4o_mini", /^gpt-4o-mini(?!-(?:audio|realtime|transcribe|tts|search))/},
          {"gpt4o_mini_audio", /^gpt-4o-mini-audio/},
          {"gpt4o_mini_realtime", /^gpt-4o-mini-realtime/},
          {"gpt4o_mini_transcribe", /^gpt-4o-mini-transcribe/},
          {"gpt4o_mini_tts", /^gpt-4o-mini-tts/},
          {"gpt4o_realtime", /^gpt-4o-realtime/},
          {"gpt4o_search", /^gpt-4o-search/},
          {"gpt4o_transcribe", /^gpt-4o-transcribe/},
          {"gpt5", /^gpt-5(?!.*(?:mini|nano))/},
          {"gpt5_mini", /^gpt-5.*mini/},
          {"gpt5_nano", /^gpt-5.*nano/},
          {"o1", /^o1(?!-(?:mini|pro))/},
          {"o1_mini", /^o1-mini/},
          {"o1_pro", /^o1-pro/},
          {"o3_mini", /^o3-mini/},
          {"babbage", /^babbage/},
          {"davinci", /^davinci/},
          {"embedding3_large", /^text-embedding-3-large/},
          {"embedding3_small", /^text-embedding-3-small/},
          {"embedding_ada", /^text-embedding-ada/},
          {"tts1", /^tts-1(?!-hd)/},
          {"tts1_hd", /^tts-1-hd/},
          {"whisper", /^whisper/},
          {"moderation", /^(?:omni|text)-moderation/},
        ]

        # family => {input, output, cached_input} (per-million). Image families omit
        # text/cached_input here (image pricing deferred — see header).
        #
        # Ruby's PRICES additionally has "price-only" families (`{ price: X }`,
        # e.g. embeddings/tts/whisper/moderation) where input==output==price (see
        # ruby's `price_for`: `prices[key] || prices[:price] || fallback`). The
        # Crystal port models those via PRICE_ONLY below, and `price_for` falls back
        # to it so an otherwise-missing family resolves to its real price instead of
        # the 0.5/1.5 default. (Image families are still deferred — header.)
        PRICES = {
          "gpt5"                  => {0.0_f64 + 1.25, 10.0, 0.125},
          "gpt5_mini"             => {0.25, 2.0, 0.025},
          "gpt5_nano"             => {0.05, 0.4, 0.005},
          "gpt41"                 => {2.0, 8.0, 0.5},
          "gpt41_mini"            => {0.4, 1.6, 0.1},
          "gpt41_nano"            => {0.1, 0.4, nil},
          "gpt4"                  => {10.0, 30.0, nil},
          "gpt4_turbo"            => {10.0, 30.0, nil},
          "gpt35_turbo"           => {0.5, 1.5, nil},
          "gpt4o"                 => {2.5, 10.0, nil},
          "gpt4o_audio"           => {2.5, 10.0, nil},
          "gpt4o_mini"            => {0.15, 0.6, nil},
          "gpt4o_mini_audio"      => {0.15, 0.6, nil},
          "gpt4o_mini_realtime"   => {0.6, 2.4, nil},
          "gpt4o_mini_transcribe" => {1.25, 5.0, nil},
          "gpt4o_mini_tts"        => {0.6, 12.0, nil},
          "gpt4o_realtime"        => {5.0, 20.0, nil},
          "gpt4o_search"          => {2.5, 10.0, nil},
          "gpt4o_transcribe"      => {2.5, 10.0, nil},
          "o1"                    => {15.0, 60.0, nil},
          "o1_mini"               => {1.1, 4.4, nil},
          "o1_pro"                => {150.0, 600.0, nil},
          "o3_mini"               => {1.1, 4.4, nil},
          "babbage"               => {0.4, 0.4, nil},
          "davinci"               => {2.0, 2.0, nil},
        } of String => Tuple(Float64, Float64, Float64?)

        # Ruby's `{ price: X }` price-only families: input == output == price, no
        # cached price. (Image families are deferred — see header — so they are not
        # listed here even though ruby carries text/images sub-pricing for them.)
        PRICE_ONLY = {
          "embedding3_large" => 0.13,
          "embedding3_small" => 0.02,
          "embedding_ada"    => 0.10,
          "tts1"             => 15.0,
          "tts1_hd"          => 30.0,
          "whisper"          => 0.006,
          "moderation"       => 0.0,
        } of String => Float64

        NIL_LIMIT_FAMILIES = %w[
          gpt_image gpt_image_mini gpt_image15 gpt4o_mini_tts tts1 tts1_hd whisper
          moderation embedding3_large embedding3_small embedding_ada
        ]

        def self.model_family(model_id : String) : String
          MODEL_PATTERNS.each do |(family, pattern)|
            return family if model_id.matches?(pattern)
          end
          "other"
        end

        def self.context_window_for(model_id : String) : Int32?
          family = model_family(model_id)
          return nil if NIL_LIMIT_FAMILIES.includes?(family)

          case family
          when "gpt41", "gpt41_mini", "gpt41_nano"
            1_047_576
          when "gpt5", "gpt5_mini", "gpt5_nano", "gpt4_turbo", "gpt4o", "gpt4o_audio",
               "gpt4o_mini", "gpt4o_mini_audio", "gpt4o_mini_realtime", "gpt4o_realtime",
               "gpt4o_search", "gpt4o_transcribe", "o1_mini"
            128_000
          when "gpt4"
            8_192
          when "gpt4o_mini_transcribe"
            16_000
          when "o1", "o1_pro", "o3_mini"
            200_000
          when "gpt35_turbo"
            16_385
          else
            4_096
          end
        end

        def self.max_tokens_for(model_id : String) : Int32?
          family = model_family(model_id)
          return nil if NIL_LIMIT_FAMILIES.includes?(family)

          case family
          when "gpt5", "gpt5_mini", "gpt5_nano"
            400_000
          when "gpt41", "gpt41_mini", "gpt41_nano"
            32_768
          when "gpt4"
            8_192
          when "gpt35_turbo"
            4_096
          when "gpt4o_mini_transcribe"
            2_000
          when "o1", "o1_pro", "o3_mini"
            100_000
          when "o1_mini"
            65_536
          else
            16_384
          end
        end

        def self.critical_capabilities_for(model_id : String) : Array(String)
          caps = [] of String
          caps << "function_calling" if supports_functions?(model_id)
          caps << "structured_output" if supports_structured_output?(model_id)
          caps << "vision" if supports_vision?(model_id)
          caps << "reasoning" if model_id.matches?(/o\d|gpt-5|codex/)
          caps
        end

        def self.supports_vision?(model_id : String) : Bool
          case model_family(model_id)
          when "gpt_image", "gpt_image_mini", "gpt_image15", "gpt5", "gpt5_mini", "gpt5_nano",
               "gpt41", "gpt41_mini", "gpt41_nano", "gpt4", "gpt4_turbo", "gpt4o", "gpt4o_mini",
               "o1", "o1_pro", "moderation", "gpt4o_search"
            true
          else
            false
          end
        end

        def self.supports_functions?(model_id : String) : Bool
          case model_family(model_id)
          when "gpt5", "gpt5_mini", "gpt5_nano", "gpt41", "gpt41_mini", "gpt41_nano", "gpt4",
               "gpt4_turbo", "gpt4o", "gpt4o_mini", "o1", "o1_pro", "o3_mini"
            true
          else
            false
          end
        end

        def self.supports_structured_output?(model_id : String) : Bool
          case model_family(model_id)
          when "gpt5", "gpt5_mini", "gpt5_nano", "gpt41", "gpt41_mini", "gpt41_nano", "gpt4o",
               "gpt4o_mini", "o1", "o1_pro", "o3_mini"
            true
          else
            false
          end
        end

        # openai/capabilities.rb: OpenAI accepts per-request tool_choice and
        # parallel-tool-call control for every model (both unconditionally true).
        def self.supports_tool_choice?(_model_id : String) : Bool
          true
        end

        def self.supports_tool_parallel_control?(_model_id : String) : Bool
          true
        end

        # Returns the wire pricing shape (text_tokens/standard) Model::Pricing consumes.
        # Image-model pricing is DEFERRED (header); image families return text-only
        # standard pricing from their input/output defaults.
        def self.pricing_for(model_id : String) : Hash(String, JSON::Any)
          standard = {
            "input_per_million"  => JSON::Any.new(input_price_for(model_id)),
            "output_per_million" => JSON::Any.new(output_price_for(model_id)),
          } of String => JSON::Any

          if cached = cached_input_price_for(model_id)
            standard["cache_read_input_per_million"] = JSON::Any.new(cached)
          end

          {
            "text_tokens" => JSON::Any.new({
              "standard" => JSON::Any.new(standard),
            } of String => JSON::Any),
          } of String => JSON::Any
        end

        def self.input_price_for(model_id : String) : Float64
          price_for(model_id, :input, 0.5)
        end

        def self.output_price_for(model_id : String) : Float64
          price_for(model_id, :output, 1.5)
        end

        def self.cached_input_price_for(model_id : String) : Float64?
          family_prices(model_id).try(&.[2])
        end

        # {input, output, cached_input?} for the model family, or nil.
        def self.family_prices(model_id : String) : Tuple(Float64, Float64, Float64?)?
          PRICES[model_family(model_id)]?
        end

        # Mirrors ruby's `prices[key] || prices[:price] || fallback`: a family with
        # explicit input/output uses those; a price-only family uses its single
        # price for both directions; everything else falls back to the default.
        def self.price_for(model_id : String, key : Symbol, fallback : Float64) : Float64
          if prices = family_prices(model_id)
            case key
            when :input  then return prices[0]
            when :output then return prices[1]
            end
          end

          if price = PRICE_ONLY[model_family(model_id)]?
            return price
          end

          fallback
        end
      end
    end
  end
end
