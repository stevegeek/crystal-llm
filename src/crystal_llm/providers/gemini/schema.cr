# ported from lib/ruby_llm/providers/gemini/chat.rb @ ruby_llm 1.16.0
#   (the GeminiSchema class + structured_output_config / response_json_schema_supported? /
#    gemini_version / build_json_schema helpers)
#
# Recursive JSON-schema -> Gemini `responseSchema` rewriter, plus the
# `responseJsonSchema`-vs-`responseSchema` version gate. Shared by BOTH the native
# Gemini provider and VertexAI (ruby_llm has `VertexAI < Gemini`; the CrystalLLM
# port has no inheritance link, so the rewriter lives module-level under
# `Providers::GeminiSchema` and both providers call it).
#
# What it does (mirrors ruby_llm's GeminiSchema):
# - Uppercases `type` values: object->OBJECT, array->ARRAY, number->NUMBER,
#   integer->INTEGER, boolean->BOOLEAN, everything-else->STRING.
# - OBJECT: rewrites `properties`, keeps `required` (stringified + de-duped) only
#   when non-empty, carries `propertyOrdering` and `nullable`.
# - ARRAY: rewrites `items` (defaults to {type: STRING}), carries minItems/maxItems/nullable.
# - Scalars: copies a type-specific allow-list of constraint keys (format/min/max/
#   enum/nullable/multipleOf for NUMBER/INTEGER; nullable for BOOLEAN; enum/format/
#   nullable for STRING).
# - `anyOf`: collapses `[T, null]`-style unions into the first non-null option with
#   `nullable: true` when a null branch is present (Gemini has no anyOf).
# - `$ref` / `$defs` / `definitions`: extracts definitions, resolves `$ref` (with
#   override-merge + cycle guard); an unresolvable `$ref` falls through to a scalar.
# - Strips unsupported keys (`strict`, `additionalProperties`).
#
# Divergences (Ruby -> Crystal):
# - ruby_llm symbolizes keys then works on symbol-keyed Hashes; on the wire here all
#   keys are already Strings (JSON::Any), so the symbolize pass collapses to String
#   keys throughout. `definition_key?`/`schema_type` compare Strings.
# - ruby_llm's `Set` of visited refs -> a `Set(String)`.
# - `Gem::Version` -> a small inline version compare (`GeminiVersion`): extract the
#   first `\d+\.\d+|\d+` from a candidate string and compare to 2.5.
# - `deep_dup`/`deep_merge` of JSON::Any -> recursive helpers here (JSON::Any is
#   immutable; we rebuild Hash/Array nodes).
require "json"
require "../../utils"
require "../../model/info"

module CrystalLLM
  module Providers
    # Gemini structured-output helpers (schema rewrite + version gate). Stateless
    # entrypoints; the recursive walk carries its own per-call state.
    module GeminiSchema
      extend self

      # Builds the `generationConfig` fragment for structured output. ruby_llm's
      # `structured_output_config`: always sets responseMimeType: application/json,
      # then gates on the model version — Gemini >= 2.5 takes a (cleaned) raw JSON
      # schema as `responseJsonSchema`; older models take the rewritten Gemini schema
      # as `responseSchema`.
      def structured_output_config(schema : JSON::Any, model : Model::Info) : Hash(String, JSON::Any)
        config = {"responseMimeType" => JSON::Any.new("application/json")} of String => JSON::Any

        if GeminiVersion.response_json_schema_supported?(model)
          config["responseJsonSchema"] = build_json_schema(schema)
        elsif converted = convert(schema)
          config["responseSchema"] = converted
        end

        config
      end

      # ruby_llm `build_json_schema`: deep_dup the inner schema, delete `strict`,
      # stringify keys. Keys are already Strings here, so this is dup + strip-strict.
      def build_json_schema(schema : JSON::Any) : JSON::Any
        inner = schema.dig?("schema") || schema
        normalized = deep_dup(inner)
        if hash = normalized.as_h?
          stripped = hash.dup
          stripped.delete("strict")
          return JSON::Any.new(stripped)
        end
        normalized
      end

      # ruby_llm `convert_schema_to_gemini`: extract the inner schema (wrapper format)
      # then run the GeminiSchema rewrite. Returns nil for a nil/non-hash schema.
      def convert(schema : JSON::Any?) : JSON::Any?
        return nil if schema.nil? || schema.raw.nil?
        inner = schema.dig?("schema") || schema
        Rewriter.new(inner).to_json_any
      end

      # ---- JSON::Any deep helpers (ruby_llm Utils.deep_dup / deep_merge) ----

      # Deep-copies a JSON::Any so the rewrite never mutates the caller's tree.
      def deep_dup(value : JSON::Any) : JSON::Any
        case raw = value.raw
        when Hash
          copy = {} of String => JSON::Any
          raw.each { |k, v| copy[k] = deep_dup(v) }
          JSON::Any.new(copy)
        when Array
          JSON::Any.new(raw.map { |item| deep_dup(item) })
        else
          value
        end
      end

      # Recursively merges `overrides` into `original` (both JSON object nodes); nested
      # objects merge, scalars/arrays from `overrides` win. Mirrors Utils.deep_merge but
      # over JSON::Any so $ref override-merge composes.
      def deep_merge(original : JSON::Any, overrides : JSON::Any) : JSON::Any
        orig_h = original.as_h?
        over_h = overrides.as_h?
        return overrides unless orig_h && over_h

        result = orig_h.dup
        over_h.each do |key, value|
          existing = result[key]?
          result[key] = if existing && existing.as_h? && value.as_h?
                          deep_merge(existing, value)
                        else
                          value
                        end
        end
        JSON::Any.new(result)
      end

      # The stateful recursive rewrite. One instance per `convert` call; it extracts
      # `$defs`/`definitions` up front, then walks the schema resolving refs.
      class Rewriter
        @definitions : Hash(String, JSON::Any)

        def initialize(raw_schema : JSON::Any)
          @raw_schema = GeminiSchema.deep_dup(raw_schema)
          @definitions = {} of String => JSON::Any
        end

        def to_json_any : JSON::Any?
          return nil if @raw_schema.raw.nil?

          extracted = extract_definitions(@raw_schema)
          convert(extracted, Set(String).new)
        end

        # ---- definition extraction ----

        # Walks the tree pulling `$defs`/`definitions` into @definitions (merging) and
        # dropping those keys from the returned schema. Mirrors ruby_llm's
        # symbolize_and_extract_definitions (minus the symbolize, keys already Strings).
        private def extract_definitions(value : JSON::Any) : JSON::Any
          case raw = value.raw
          when Hash
            result = {} of String => JSON::Any
            raw.each do |key, val|
              if definition_key?(key)
                merge_definitions(val)
              else
                result[key] = extract_definitions(val)
              end
            end
            JSON::Any.new(result)
          when Array
            JSON::Any.new(raw.map { |item| extract_definitions(item) })
          else
            value
          end
        end

        private def definition_key?(key : String) : Bool
          key == "$defs" || key == "definitions"
        end

        private def merge_definitions(raw_defs : JSON::Any) : Nil
          return if raw_defs.raw.nil?
          extracted = extract_definitions(raw_defs)
          defs_hash = extracted.as_h? || return
          @definitions = if @definitions.empty?
                           defs_hash.dup
                         else
                           (GeminiSchema.deep_merge(JSON::Any.new(@definitions), JSON::Any.new(defs_hash)).as_h? || @definitions)
                         end
        end

        # ---- the recursive convert ----

        private def convert(schema : JSON::Any, visited_refs : Set(String)) : JSON::Any
          schema_hash = schema.as_h?
          return default_string_schema unless schema_hash

          schema_hash = strip_unsupported_keys(schema_hash)

          if ref = schema_hash["$ref"]?.try(&.as_s?)
            resolved = resolve_reference(ref, schema_hash, visited_refs)
            return resolved if resolved
          end

          schema_hash = normalize_any_of(schema_hash)

          result = case type_of(schema_hash)
                   when "object"
                     build_object(schema_hash, visited_refs)
                   when "array"
                     build_array(schema_hash, visited_refs)
                   when "number"
                     build_scalar("NUMBER", schema_hash, %w[format minimum maximum enum nullable multipleOf])
                   when "integer"
                     build_scalar("INTEGER", schema_hash, %w[format minimum maximum enum nullable multipleOf])
                   when "boolean"
                     build_scalar("BOOLEAN", schema_hash, %w[nullable])
                   else
                     build_scalar("STRING", schema_hash, %w[enum format nullable])
                   end

          apply_description(result, schema_hash)
          JSON::Any.new(result)
        end

        private def type_of(schema_hash : Hash(String, JSON::Any)) : String
          value = schema_hash["type"]?
          return "" if value.nil?
          (value.as_s? || value.raw.to_s).downcase
        end

        private def strip_unsupported_keys(schema_hash : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          copy = schema_hash.dup
          copy.delete("strict")
          copy.delete("additionalProperties")
          copy
        end

        # ---- $ref resolution ----

        private def resolve_reference(ref : String, schema_hash : Hash(String, JSON::Any),
                                      visited_refs : Set(String)) : JSON::Any?
          return nil if visited_refs.includes?(ref)

          referenced = lookup_definition(ref)
          return nil unless referenced

          overrides = schema_hash.dup
          overrides.delete("$ref")

          visited_refs.add(ref)
          begin
            merged = GeminiSchema.deep_merge(referenced, JSON::Any.new(overrides))
            convert(merged, visited_refs)
          ensure
            visited_refs.delete(ref)
          end
        end

        # Walks a `#/$defs/Name` (or `#/definitions/Name`) pointer into @definitions.
        private def lookup_definition(ref : String) : JSON::Any?
          segments = ref.split("/").reject(&.empty?)
          return nil if segments.empty?

          segments.shift if segments.first? == "#"
          first = segments.first?
          segments.shift if first == "$defs" || first == "definitions"

          current : JSON::Any? = JSON::Any.new(@definitions)
          segments.each do |segment|
            hash = current.try(&.as_h?)
            return nil unless hash
            current = hash[segment]?
          end

          current.nil? ? nil : GeminiSchema.deep_dup(current)
        end

        # ---- anyOf normalization ----

        # Collapses `anyOf` into a single base schema; a `null` branch sets nullable.
        private def normalize_any_of(schema_hash : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          any_of = schema_hash["anyOf"]?.try(&.as_a?)
          return schema_hash unless any_of

          nullable = false
          non_null = [] of Hash(String, JSON::Any)
          any_of.each do |option|
            option_hash = option.as_h? || next
            if option_type(option_hash) == "null"
              nullable = true
            else
              non_null << option_hash
            end
          end

          base = (non_null.first?.try(&.dup)) || {"type" => JSON::Any.new("string")} of String => JSON::Any
          base["nullable"] = JSON::Any.new(true) if nullable

          result = {} of String => JSON::Any
          schema_hash.each { |key, value| result[key] = value unless key == "anyOf" }
          base.each { |key, value| result[key] = value }
          result
        end

        private def option_type(option_hash : Hash(String, JSON::Any)) : String
          value = option_hash["type"]?
          return "" if value.nil?
          (value.as_s? || value.raw.to_s).downcase
        end

        # ---- node builders ----

        private def build_object(schema_hash : Hash(String, JSON::Any),
                                 visited_refs : Set(String)) : Hash(String, JSON::Any)
          properties = {} of String => JSON::Any
          if props = schema_hash["properties"]?.try(&.as_h?)
            props.each { |key, child| properties[key] = convert(child, visited_refs) }
          end

          object = {
            "type"       => JSON::Any.new("OBJECT"),
            "properties" => JSON::Any.new(properties),
          } of String => JSON::Any

          required = required_strings(schema_hash["required"]?)
          object["required"] = JSON::Any.new(required.map { |name| JSON::Any.new(name) }) unless required.empty?

          if ordering = schema_hash["propertyOrdering"]?
            object["propertyOrdering"] = ordering
          end
          copy_attribute(object, schema_hash, "nullable")
          object
        end

        private def build_array(schema_hash : Hash(String, JSON::Any),
                                visited_refs : Set(String)) : Hash(String, JSON::Any)
          items = schema_hash["items"]?
          items_schema = items ? convert(items, visited_refs) : default_string_schema

          array = {
            "type"  => JSON::Any.new("ARRAY"),
            "items" => items_schema,
          } of String => JSON::Any

          copy_attribute(array, schema_hash, "minItems")
          copy_attribute(array, schema_hash, "maxItems")
          copy_attribute(array, schema_hash, "nullable")
          array
        end

        private def build_scalar(type : String, schema_hash : Hash(String, JSON::Any),
                                 allowed_keys : Array(String)) : Hash(String, JSON::Any)
          result = {"type" => JSON::Any.new(type)} of String => JSON::Any
          allowed_keys.each { |key| copy_attribute(result, schema_hash, key) }
          result
        end

        # ---- small helpers ----

        # ruby_llm `Array(schema[:required]).map(&:to_s).uniq`.
        private def required_strings(value : JSON::Any?) : Array(String)
          arr = value.try(&.as_a?)
          return [] of String unless arr
          seen = [] of String
          arr.each do |entry|
            str = entry.as_s? || entry.raw.to_s
            seen << str unless seen.includes?(str)
          end
          seen
        end

        private def apply_description(target : Hash(String, JSON::Any),
                                      schema_hash : Hash(String, JSON::Any)) : Nil
          if description = schema_hash["description"]?
            target["description"] = description
          end
        end

        private def copy_attribute(target : Hash(String, JSON::Any),
                                   source : Hash(String, JSON::Any), key : String) : Nil
          target[key] = source[key] if source.has_key?(key)
        end

        private def default_string_schema : JSON::Any
          JSON::Any.new({"type" => JSON::Any.new("STRING")} of String => JSON::Any)
        end
      end
    end

    # The `responseJsonSchema`-vs-`responseSchema` version gate. ruby_llm uses
    # `Gem::Version` over a list of candidate strings (model id / family / metadata
    # version / metadata description); >= 2.5 supports responseJsonSchema. Crystal has
    # no Gem::Version, so we extract the leading `\d+\.\d+|\d+` and compare numerically.
    module GeminiVersion
      extend self

      THRESHOLD = {2, 5}

      def response_json_schema_supported?(model : Model::Info?) : Bool
        version = gemini_version(model)
        return false unless version
        compare(version, THRESHOLD) >= 0
      end

      # First parseable version across the candidate strings (id, family, metadata
      # `version`/`description`). Returns a {major, minor} tuple or nil.
      def gemini_version(model : Model::Info?) : Tuple(Int32, Int32)?
        return nil unless model

        candidates = [
          model.id,
          model.family,
          metadata_string(model, "version"),
          metadata_string(model, "description"),
        ]

        candidates.each do |candidate|
          if version = extract_version(candidate)
            return version
          end
        end
        nil
      end

      private def metadata_string(model : Model::Info, key : String) : String?
        value = model.metadata[key]?
        return nil if value.nil?
        value.as_s? || (value.raw.nil? ? nil : value.raw.to_s)
      end

      # Extracts a leading `major.minor` (or bare `major`, minor defaulting to 0).
      def extract_version(text : String?) : Tuple(Int32, Int32)?
        return nil if text.nil? || text.empty?
        match = text.match(/(\d+)\.(\d+)|(\d+)/)
        return nil unless match
        if (major = match[1]?) && (minor = match[2]?)
          {major.to_i, minor.to_i}
        elsif bare = match[3]?
          {bare.to_i, 0}
        end
      end

      private def compare(a : Tuple(Int32, Int32), b : Tuple(Int32, Int32)) : Int32
        cmp = a[0] <=> b[0]
        return cmp unless cmp.zero?
        a[1] <=> b[1]
      end
    end
  end
end
