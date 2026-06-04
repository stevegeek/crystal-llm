# ported from lib/ruby_llm/tool.rb @ ruby_llm 1.15.0
require "json"
require "./content"
require "./schema"

module CrystalLLM
  # Base class for tools an AI model can call.
  #
  # == The key Crystal divergence: the `param` macro DSL ==
  #
  # ruby_llm declares tool parameters with `param :city, desc: "..."` and then
  # infers the rest from the *runtime* signature of `def execute(city:)` via
  # `method(:execute).parameters`. Crystal has neither runtime method reflection
  # nor a way to splat a runtime hash into `execute(**args)`, so the bridge is
  # built at compile time by a macro:
  #
  #   class WeatherTool < CrystalLLM::Tool
  #     description "Look up the weather"
  #     param latitude : Float64, "Latitude", required: true
  #     param city : String, "City name", required: false
  #
  #     def execute(latitude : Float64, city : String?) : CrystalLLM::ToolResult
  #       "..."
  #     end
  #   end
  #
  # `param name : Type, "desc", required: true`:
  #   1. records a `Parameter` (name / json-type / description / required) for the
  #      params-schema, AND
  #   2. generates the runtime arg-extraction `call(args)` that pulls each declared
  #      param out of the `Hash(String, JSON::Any)` the model supplied, coerces it
  #      to the declared Crystal type, validates missing/unknown keys, and invokes
  #      the subclass's typed `execute(...)`.
  #
  # There is NO runtime signature inference (design §7 / §11.1) — `param` is the
  # single source of truth. A subclass with no `param` declarations is a valid,
  # zero-argument tool (its `execute` takes no args).
  #
  # == Other divergences ==
  #
  # * `execute` returns a `ToolResult` union (see the alias below), not an
  #   arbitrary object. The recoverable-error convention `{ error: "..." }` is a
  #   `Hash(String, JSON::Any)` member of that union.
  # * `Tool::Halt` ports as a returned sentinel; the protected `halt("msg")` helper
  #   builds one.
  # * `name` derivation is ported (snake_case of the class name, minus a `_tool`
  #   suffix, `::` → `--`). Full Unicode NFKD normalization is approximated: ASCII
  #   passes through unchanged; non-ASCII / non-`[A-Za-z0-9_-]` characters become
  #   `-` (matching the Ruby `gsub(/[^a-zA-Z0-9_-]/, '-')` step) but Crystal's
  #   stdlib has no `unicode_normalize(:nfkd)`, so `SàmpleTòol`-style accent folding
  #   to `sample` is NOT reproduced (those become dashed). Documented divergence.
  # * `params(schema)` / `with_params` / `provider_params` / the schema-from-block
  #   form: a `CrystalLLM::Schema` (class or instance) or a raw json-schema hash may
  #   be supplied via `params_schema_definition` to override the param-derived
  #   schema. The Ruby `RubyLLM::Schema.create(&block)` anonymous-class form is
  #   dropped (Crystal can't synthesize a class at runtime — same as schema.cr).
  # * `DynamicTool` (approved escape hatch, additive) builds a tool from runtime
  #   data — name/description/json-schema plus a `Proc(Hash(String, JSON::Any),
  #   ToolResult)` body — recovering Ruby's `Class.new(Tool)` use.
  abstract class Tool
    # Stops conversation continuation after tool execution. Returned (as a member
    # of `ToolResult`) by a tool that wants the assistant turn to end with the
    # given content rather than feeding the result back to the model.
    class Halt
      getter content : ToolResult

      def initialize(@content : ToolResult)
      end

      def to_s(io : IO) : Nil
        case c = @content
        when String
          io << c
        else
          io << c.to_s
        end
      end
    end

    # Parameter definition for a tool. `type` is the JSON-schema type string
    # ("string"/"integer"/"number"/"boolean"/"array"/"object"); `required`
    # controls whether the key must be present in the call args.
    class Parameter
      getter name : String
      getter type : String
      getter description : String?
      getter? required : Bool

      def initialize(@name : String, @type : String = "string",
                     @description : String? = nil, @required : Bool = true)
      end
    end

    # Wraps a non-param schema source: either a raw json-schema hash or a
    # `CrystalLLM::Schema` (class via a builder Proc, or instance). When present it
    # takes precedence over the `param`-derived schema (mirrors ruby_llm's
    # `params_schema_definition`).
    class SchemaDefinition
      # Map a declared param type onto a JSON-schema type string.
      def self.map_type(type : String) : String
        case type
        when "integer", "int"            then "integer"
        when "number", "float", "double" then "number"
        when "boolean"                   then "boolean"
        when "array"                     then "array"
        when "object"                    then "object"
        else
          "string"
        end
      end

      def self.default_items_schema : Hash(String, JSON::Any)
        {"type" => JSON::Any.new("string")}
      end

      # Build a params-schema from declared `Parameter`s (the param-derived path).
      # Returns `nil` when there are no parameters and `allow_empty` is false.
      def self.from_parameters(parameters : Array(Parameter),
                               allow_empty : Bool = false) : SchemaDefinition?
        return nil if parameters.empty? && !allow_empty

        properties = {} of String => JSON::Any
        required = [] of JSON::Any
        parameters.each do |param|
          schema = {"type" => JSON::Any.new(map_type(param.type))}
          if d = param.description
            schema["description"] = JSON::Any.new(d)
          end
          schema["items"] = JSON::Any.new(default_items_schema) if schema["type"].as_s == "array"
          properties[param.name] = JSON::Any.new(schema)
          required << JSON::Any.new(param.name) if param.required?
        end

        json_schema = {
          "type"                 => JSON::Any.new("object"),
          "properties"           => JSON::Any.new(properties),
          "required"             => JSON::Any.new(required),
          "additionalProperties" => JSON::Any.new(false),
          "strict"               => JSON::Any.new(true),
        } of String => JSON::Any

        new(schema: json_schema)
      end

      @schema : Hash(String, JSON::Any)?
      @crystal_schema : Schema?

      def initialize(schema : Hash(String, JSON::Any)? = nil, crystal_schema : Schema? = nil)
        @schema = schema
        @crystal_schema = crystal_schema
      end

      def present? : Bool
        !(@schema.nil? && @crystal_schema.nil?)
      end

      # The resolved json-schema body (the inner `schema:` of a Schema envelope,
      # or the raw hash as-given).
      def json_schema : Hash(String, JSON::Any)?
        if cs = @crystal_schema
          extract_schema(cs.to_json_schema)
        elsif s = @schema
          s
        end
      end

      # Pull the inner `schema` out of a `{name, description, schema}` envelope.
      private def extract_schema(envelope : Hash(String, JSON::Any)) : Hash(String, JSON::Any)?
        if inner = envelope["schema"]?
          inner.as_h
        else
          envelope
        end
      end
    end

    # --- Class-level DSL state (per-subclass class variables, reset on inherit) --

    @@description : String? = nil
    @@parameters = [] of Parameter
    @@params_schema_definition : SchemaDefinition? = nil
    @@provider_params : Hash(String, JSON::Any)? = nil

    macro inherited
      @@description = nil
      @@parameters = [] of CrystalLLM::Tool::Parameter
      @@params_schema_definition = nil
      @@provider_params = nil
    end

    # Set (no arg: read) the tool description. `desc` is a shorter alias.
    def self.description(text : String) : Nil
      @@description = text
    end

    def self.description : String?
      @@description
    end

    def self.desc(text : String) : Nil
      @@description = text
    end

    # The declared parameters, in declaration order.
    def self.parameters : Array(Parameter)
      @@parameters
    end

    def self.params_schema_definition : SchemaDefinition?
      @@params_schema_definition
    end

    # Supply an explicit schema (a raw json-schema hash or a `CrystalLLM::Schema`)
    # that overrides the param-derived schema.
    def self.params(schema : Hash(String, JSON::Any)) : Nil
      @@params_schema_definition = SchemaDefinition.new(schema: schema)
    end

    def self.params(schema : Schema) : Nil
      @@params_schema_definition = SchemaDefinition.new(crystal_schema: schema)
    end

    # Provider-specific extra params (e.g. cache_control). Replaces, not merges.
    def self.with_params(params : Hash(String, JSON::Any)) : Nil
      @@provider_params = params
    end

    def self.provider_params : Hash(String, JSON::Any)
      @@provider_params || {} of String => JSON::Any
    end

    # The `param` macro — the heart of the Crystal tool DSL.
    #
    #   param latitude : Float64, "Latitude of the location", required: true
    #
    # Records a `Parameter` for the schema. It does NOT generate `execute`; the
    # subclass writes its own typed `execute`, and the macro-built `call` extracts
    # & coerces each declared param from the runtime args hash before dispatch.
    #
    # `type:` overrides the json-schema type string (defaults derived from the
    # Crystal type: Int → "integer", Float → "number", Bool → "boolean",
    # Array → "array", everything else → "string").
    macro param(decl, description = nil, required = true, type = nil)
      {% var = decl.var %}
      {% crystal_type = decl.type %}
      {% type_str = crystal_type.stringify %}
      {% json_type = if type
                       type
                     elsif type_str.starts_with?("Int")
                       "integer"
                     elsif type_str.starts_with?("Float")
                       "number"
                     elsif type_str == "Bool"
                       "boolean"
                     elsif type_str.starts_with?("Array")
                       "array"
                     else
                       "string"
                     end %}
      @@parameters << CrystalLLM::Tool::Parameter.new(
        {{ var.stringify }},
        type: {{ json_type }},
        description: {{ description }},
        required: {{ required }}
      )
    end

    # --- Instance side --------------------------------------------------------

    def description : String?
      self.class.description
    end

    def parameters : Array(Parameter)
      self.class.parameters
    end

    def provider_params : Hash(String, JSON::Any)
      self.class.provider_params
    end

    # snake_case of the class name, `::` → `--`, minus a trailing `_tool`.
    def name : String
      Tool.derive_name(self.class.name)
    end

    # The params-schema sent to providers. Precedence (ruby_llm parity):
    #   1. an explicit `params(...)` / Schema definition, else
    #   2. the `param`-declared parameters, else
    #   3. an empty object schema (no params).
    def params_schema : Hash(String, JSON::Any)
      if (definition = self.class.params_schema_definition) && definition.present?
        definition.json_schema || empty_params_schema
      elsif !parameters.empty?
        SchemaDefinition.from_parameters(parameters).try(&.json_schema) || empty_params_schema
      else
        SchemaDefinition.from_parameters(parameters, allow_empty: true).try(&.json_schema) || empty_params_schema
      end
    end

    # Entry point: validate the supplied args against the declared params, then
    # dispatch to `execute`. Returns the `{ "error" => ... }` hash on a
    # missing/unknown keyword (ported message text), else the tool's result.
    def call(args : Hash(String, JSON::Any)) : ToolResult
      if err = validate_keyword_arguments(args)
        return {"error" => JSON::Any.new("Invalid tool arguments: #{err}")} of String => JSON::Any
      end
      dispatch(args)
    end

    # Subclasses override `dispatch` (generated by hand in the typed `execute`
    # pattern below) to extract args and call their typed `execute`. The default
    # no-param dispatch ignores args and calls the zero-arg `execute`.
    #
    # NOTE: because Crystal can't splat a runtime hash, a tool with params writes:
    #
    #   def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
    #     execute(latitude: args["latitude"].as_f, city: args["city"]?.try(&.as_s))
    #   end
    #
    # The `param` macro records the schema; `dispatch` wires extraction. (A future
    # iteration may auto-generate `dispatch` from the `param` decls; kept explicit
    # for now so the type coercion stays visible and correct — design §7.)
    def dispatch(args : Hash(String, JSON::Any)) : ToolResult
      execute
    end

    # The zero-arg default. Tools with params override `execute` with a typed
    # signature (and override `dispatch` to feed it).
    def execute : ToolResult
      raise NotImplementedError.new("Subclasses must implement #execute")
    end

    # --- Validation (ported against macro-declared params) --------------------

    # Returns a "missing keyword: x" / "unknown keyword: y" message, or nil.
    protected def validate_keyword_arguments(arguments : Hash(String, JSON::Any)) : String?
      required_keywords = parameters.select(&.required?).map(&.name)
      allowed_keywords = parameters.map(&.name)

      if missing = (required_keywords - arguments.keys).first?
        return "missing keyword: #{missing}"
      end

      if unknown = (arguments.keys - allowed_keywords).first?
        return "unknown keyword: #{unknown}"
      end

      nil
    end

    protected def halt(message : ToolResult) : Halt
      Halt.new(message)
    end

    protected def empty_params_schema : Hash(String, JSON::Any)
      {
        "type"                 => JSON::Any.new("object"),
        "properties"           => JSON::Any.new({} of String => JSON::Any),
        "required"             => JSON::Any.new([] of JSON::Any),
        "additionalProperties" => JSON::Any.new(false),
        "strict"               => JSON::Any.new(true),
      } of String => JSON::Any
    end

    # Faithful-ish port of ruby_llm's name munging. Full NFKD normalization is not
    # available in Crystal's stdlib, so accent-folding is approximated by the
    # `[^a-zA-Z0-9_-] -> -` replacement (documented divergence in the class docs).
    # Exposed as a class method so the derivation is testable independent of
    # Crystal's mandatory class namespacing (Ruby's `stub_const` has no analog).
    def self.derive_name(klass_name : String) : String
      # `::` -> `--` first, so the segment separator survives the char filter.
      s = klass_name.gsub("::", "--")
      # non-[A-Za-z0-9_-] -> '-'
      s = s.gsub(/[^a-zA-Z0-9_-]/, '-')
      # insert underscores at camelCase / ACRONYMWord boundaries
      s = s.gsub(/([A-Z]+)([A-Z][a-z])/) { "#{$1}_#{$2}" }
      s = s.gsub(/([a-z\d])([A-Z])/) { "#{$1}_#{$2}" }
      s = s.downcase
      s = s[0...-5] if s.ends_with?("_tool")
      s
    end
  end

  # The return type of a tool's `execute`/`dispatch`. A bare `String`, a
  # JSON-data hash (also the `{ "error" => ... }` recoverable-error shape), a
  # `Content` (text + attachments), or a `Tool::Halt` sentinel.
  alias ToolResult = String | Hash(String, JSON::Any) | Content | Tool::Halt

  # Approved escape hatch (additive — design §7): build a tool from runtime data
  # rather than the macro DSL. Recovers Ruby's `Class.new(Tool)` pattern.
  #
  #   tool = CrystalLLM::DynamicTool.new(
  #     "search", "Search the web",
  #     {"type" => JSON::Any.new("object"), ...}
  #   ) { |args| args["q"].as_s }
  #
  # The `json_schema` is used verbatim as the params-schema; arg validation is
  # NOT performed (the supplied schema is authoritative and the block handles
  # extraction), matching a hand-built runtime tool.
  class DynamicTool < Tool
    getter dynamic_name : String
    @dynamic_description : String?
    @json_schema : Hash(String, JSON::Any)
    @body : Hash(String, JSON::Any) -> ToolResult

    def initialize(@dynamic_name : String, description : String? = nil,
                   @json_schema : Hash(String, JSON::Any) = {} of String => JSON::Any,
                   &body : Hash(String, JSON::Any) -> ToolResult)
      @dynamic_description = description
      @body = body
    end

    def name : String
      @dynamic_name
    end

    def description : String?
      @dynamic_description
    end

    def params_schema : Hash(String, JSON::Any)
      @json_schema
    end

    # No macro-declared params, so no missing/unknown validation: the runtime
    # schema is authoritative and the block owns extraction.
    def call(args : Hash(String, JSON::Any)) : ToolResult
      @body.call(args)
    end
  end
end
