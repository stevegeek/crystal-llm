# ported from lib/ruby_llm/providers/openai/moderation.rb @ ruby_llm 1.15.0
#
# OpenAI moderation hooks (moderation_url / render_moderation_payload /
# parse_moderation_response), reopening Providers::OpenAI.
#
# Divergences:
# - `response.body` is a raw JSON String (Crest); parse JSON.parses it.
# - `input` is `Provider::TextInput` (String | Array(String)) — design §11.
# - `results` is carried verbatim as `Array(JSON::Any)` (the Moderation data class's
#   wire shape — see moderation.cr); `id`/`model` are Strings.
require "json"
require "../openai"
require "../../provider_media"
require "../../moderation"

module CrystalLLM
  module Providers
    class OpenAI < Provider
      def moderation_url : String
        "moderations"
      end

      def render_moderation_payload(input : Provider::TextInput, model : String) : Hash(String, JSON::Any)
        {
          "model" => JSON::Any.new(model),
          "input" => input_to_json(input),
        } of String => JSON::Any
      end

      def parse_moderation_response(response : Crest::Response, model : String) : Moderation
        data = JSON.parse(response.body)

        if msg = data.dig?("error", "message").try(&.as_s?)
          raise Error.new(response, msg)
        end

        results = data["results"]?.try(&.as_a?) || [] of JSON::Any

        Moderation.new(
          id: data["id"]?.try(&.as_s?) || "",
          model: model,
          results: results
        )
      end

      private def input_to_json(input : Provider::TextInput) : JSON::Any
        case input
        when String
          JSON::Any.new(input)
        else
          JSON::Any.new(input.map { |item| JSON::Any.new(item) })
        end
      end
    end
  end
end
