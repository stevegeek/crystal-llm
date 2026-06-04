# ported from lib/ruby_llm/providers/bedrock/models.rb @ ruby_llm 1.15.0
#
# Models listing for AWS Bedrock (`/foundation-models` on the bedrock control-plane
# host, not the runtime host used for chat).
#
# Divergences:
# - `response.body` is a raw String (Crest); JSON.parse it here.
# - ruby_llm's `list_models` issues a *signed* GET to `models_api_base`; the frozen
#   pipeline's `list_models` GETs `models_url` against `api_base`. The signed/host
#   override is DEFERRED with the auth wiring (see bedrock/auth.cr). `models_api_base`
#   is ported for when that lands. `parse_list_models_response` itself is exact.
# - Model::Info built via `.build` (the native-value keyword constructor); modalities
#   wrapped in Model::Modalities, pricing left empty (`Model::Pricing.new`).
# - `@config.bedrock_region` read directly (ruby_llm threads it through the mixin).
require "json"
require "../bedrock"
require "../../model/modalities"
require "../../model/pricing"

module CrystalLLM
  module Providers
    class Bedrock < Provider
      REGION_PREFIXES = %w[global us eu ap sa ca me af il]

      def models_url : String
        "/foundation-models"
      end

      # AUTH/HOST DEFERRED: the control-plane host for the models endpoint.
      def models_api_base : String
        "https://bedrock.#{@config.bedrock_region}.amazonaws.com"
      end

      def parse_list_models_response(response : Crest::Response, slug : String,
                                     capabilities : CrystalLLM::Capabilities.class) : Array(Model::Info)
        body = response.body
        return [] of Model::Info if body.empty?

        data = JSON.parse(body)
        summaries = data["modelSummaries"]?.try(&.as_a?) || [] of JSON::Any

        summaries.compact_map do |model_any|
          model_data = model_any.as_h? || next
          create_model_info(model_data, slug)
        end
      end

      private def create_model_info(model_data : Hash(String, JSON::Any), slug : String) : Model::Info
        model_id = model_id_with_region(model_data["modelId"]?.try(&.as_s?) || "", model_data)
        converse_data = model_data["converse"]?.try(&.as_h?) || {} of String => JSON::Any

        family = model_data["modelFamily"]?.try(&.as_s?) ||
                 model_data["providerName"]?.try(&.as_s?).try(&.downcase)

        max_output = int_at(converse_data["maxTokensDefault"]?) || int_at(converse_data["maxTokensMaximum"]?)

        modalities = Model::Modalities.new(
          input: normalize_modalities(model_data["inputModalities"]?),
          output: normalize_modalities(model_data["outputModalities"]?)
        )

        metadata = {
          "provider_name"   => model_data["providerName"]? || JSON::Any.new(nil),
          "model_arn"       => model_data["modelArn"]? || JSON::Any.new(nil),
          "inference_types" => model_data["inferenceTypesSupported"]? || JSON::Any.new(nil),
          "converse"        => JSON::Any.new(converse_data),
        } of String => JSON::Any

        Model::Info.build(
          id: model_id,
          name: model_data["modelName"]?.try(&.as_s?),
          provider: slug,
          family: family,
          created_at: nil,
          context_window: parse_context_window(model_data),
          max_output_tokens: max_output,
          modalities: modalities,
          capabilities: parse_capabilities(model_data),
          pricing: Model::Pricing.new,
          metadata: metadata
        )
      end

      # ---- Region-prefixed model id normalization ----

      private def model_id_with_region(model_id : String, model_data : Hash(String, JSON::Any)) : String
        inference_types = string_array(model_data["inferenceTypesSupported"]?)
        normalize_inference_profile_id(model_id, inference_types, @config.bedrock_region)
      end

      private def normalize_inference_profile_id(model_id : String, inference_types : Array(String),
                                                 region : String?) : String
        return model_id unless inference_types.includes?("INFERENCE_PROFILE")
        return model_id if inference_types.includes?("ON_DEMAND")

        with_region_prefix(model_id, region)
      end

      private def with_region_prefix(model_id : String, region : String?) : String
        prefix = region_prefix(region)

        if region_prefixed?(model_id)
          model_id.sub(/\A(?:#{REGION_PREFIXES.join("|")})\./, "#{prefix}.")
        else
          "#{prefix}.#{model_id}"
        end
      end

      private def region_prefix(region : String?) : String
        prefix = region.to_s.split('-').first?
        (prefix.nil? || prefix.empty?) ? "us" : prefix
      end

      private def region_prefixed?(model_id : String) : Bool
        !!model_id.match(/\A(?:#{REGION_PREFIXES.join("|")})\./)
      end

      private def normalize_modalities(modalities : JSON::Any?) : Array(String)
        string_array(modalities).map do |modality|
          normalized = modality.downcase
          case normalized
          when "embedding" then "embeddings"
          when "speech"    then "audio"
          else                  normalized
          end
        end
      end

      # ---- Capabilities derived from the summary row ----

      private def parse_capabilities(model_data : Hash(String, JSON::Any)) : Array(String)
        capabilities = [] of String
        capabilities << "streaming" if truthy?(model_data["responseStreamingSupported"]?)

        converse = model_data["converse"]?.try(&.as_h?)
        if converse
          capabilities << "function_calling"
          capabilities << "reasoning" if truthy?(converse.dig?("reasoningSupported", "embedded"))
        end

        if supports_structured_output?(model_data["modelId"]?.try(&.as_s?))
          capabilities << "structured_output"
        end

        capabilities
      end

      # Structured output supported on Claude 4.5+ (and assumed for future majors).
      # Handles optional region prefix (us./eu./global.) and the anthropic. prefix.
      def supports_structured_output?(model_id : String?) : Bool
        return false unless model_id

        normalized = model_id.sub(/\A(?:#{REGION_PREFIXES.join("|")})\./, "")
        normalized = normalized.lchop("anthropic.")
        match = normalized.match(/claude-(?:opus|sonnet|haiku)-(\d+)-(\d{1,2})(?:\b|-)/)
        return false unless match

        major = match[1].to_i
        minor = match[2].to_i
        major > 4 || (major == 4 && minor >= 5)
      end

      private def parse_context_window(model_data : Hash(String, JSON::Any)) : Int32?
        value = model_data.dig?("description", "maxContextWindow").try(&.as_s?)
        return nil unless value

        if value.match(/\A\d+[kK]\z/)
          value[0...-1].to_i * 1000
        elsif value.match(/\A\d+\z/)
          value.to_i
        end
      end

      private def truthy?(value : JSON::Any?) : Bool
        return false if value.nil?
        case raw = value.raw
        when Bool then raw
        when Nil  then false
        else           true
        end
      end

      private def string_array(value : JSON::Any?) : Array(String)
        return [] of String if value.nil?
        arr = value.as_a?
        return [] of String if arr.nil?
        arr.compact_map { |element| element.as_s? || (element.raw.nil? ? nil : element.raw.to_s) }
      end
    end
  end
end
