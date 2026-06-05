# ported from ruby_llm-schema lib/ruby_llm/schema.rb @ 0.4.0
require "json"

module CrystalLLM
  # A declarative JSON-Schema DSL, ported from the standalone `ruby_llm-schema`
  # gem (v0.4.0). It produces the same wire shape ruby_llm sends to providers for
  # structured output:
  #
  #   { name, description, schema: { type: "object", properties, required,
  #                                  additionalProperties, strict } }
  #
  # Usage (a class-body DSL):
  #
  #   class Person < CrystalLLM::Schema
  #     string  "name", description: "Full name"
  #     integer "age",  required: false, minimum: 0
  #     object  "address" do |o|
  #       o.string "city"
  #     end
  #     array "tags", of: :string
  #   end
  #
  #   Person.new("person", description: "A person").to_json_schema
  #
  # == Divergences from the Ruby gem (documented, idiomatic Crystal) ==
  #
  # * The Ruby gem uses `class_eval`/`instance_eval` so the DSL reads as bare
  #   method calls inside a block. Crystal has no runtime `class_eval` against a
  #   fresh receiver, so:
  #     - The *class-body* DSL works via class methods that mutate per-subclass
  #       class variables. Crystal class variables are isolated per subclass
  #       (verified), and `macro inherited` resets them for each subclass.
  #     - *Nested* object / array-of-object schemas take an EXPLICIT builder block
  #       parameter: `object("addr") { |o| o.string("city") }` rather than the
  #       Ruby `object("addr") { string("city") }`.
  # * Wire data is `JSON::Any` (alias `Hash(String, JSON::Any)`), per the port's
  #   convention — Ruby symbol-keyed hashes become String-keyed `JSON::Any`.
  # * `Schema.create(&block)` (anonymous runtime class generation) is dropped:
  #   Crystal cannot synthesize a class at runtime. Define a named subclass.
  #
  # == Now ported (this phase, PORTING.md #9) ==
  #
  # * Composition: `any_of(name, &block)`, `one_of(name, &block)`,
  #   `optional(name, &block)` (= `any_of` with a trailing `null`). The block
  #   takes an explicit member builder (`|m|`) collecting alternative schemas
  #   into `anyOf` / `oneOf` (Crystal divergence — Ruby uses an `instance_eval`
  #   context that resolves bare method calls).
  # * `$defs` / references: `define(name) { |d| ... }` adds a named definition to
  #   `$defs`; `reference(name)` yields `{"$ref" => "#/$defs/name"}` (and
  #   `reference(:root)` / `reference("#")` yields `{"$ref" => "#"}`).
  # * The runtime validator (`validate!` / `valid?`): a faithful port of
  #   `validator.rb` — DFS-based circular-reference detection over `$defs`. The
  #   `to_json_schema` / `to_json` entry points run `validate!` first, as Ruby does.
  #
  # == Now ported (this phase) — conditionals ==
  #
  # * `requires:` keyword on any property declaration (string/number/.../object/
  #   array/any_of/one_of): the property, when present, requires the listed
  #   fields — emitted as `dependentRequired`.
  # * `given(prop: value, ...) { |c| c.requires(...); c.validates(...);
  #   c.otherwise { |o| ... } }` — an if/then(/else) conditional, emitted as a
  #   single inline `if`/`then`/`else` when there is one `given`, or wrapped in
  #   `allOf` when there are several.
  # * `dependent(prop) { |b| b.requires(...); b.validates(...) }` — a schema-level
  #   dependency: when `prop` is present the block's constraints apply. Emitted as
  #   `dependentRequired` (when only `requires`) or `dependentSchemas`.
  #
  # Crystal divergence: Ruby uses `instance_eval` so the conditional block reads
  # as bare `requires`/`validates`/`otherwise` calls. Here the block takes an
  # explicit builder/context parameter (`|c|`, `|b|`, `|o|`).
  class Schema
    # Per-subclass DSL state. Class variables are isolated per subclass in
    # Crystal; `macro inherited` re-initializes them so each subclass starts clean.
    @@builder = Builder.new
    @@schema_name : String? = nil
    @@description : String? = nil
    @@additional_properties = false
    @@strict : Bool? = true
    @@definitions = {} of String => JSON::Any
    # `given` conditionals (each an if/then[/else] schema fragment) and
    # `dependent`/`requires:` dependencies (property name => builder).
    @@conditions = [] of Hash(String, JSON::Any)
    @@dependencies = {} of String => ConditionalBuilder

    macro inherited
      @@builder = Builder.new
      @@schema_name = nil
      @@description = nil
      @@additional_properties = false
      @@strict = true
      @@definitions = {} of String => JSON::Any
      @@conditions = [] of Hash(String, JSON::Any)
      @@dependencies = {} of String => CrystalLLM::Schema::ConditionalBuilder
    end

    # The accumulated properties for this schema class.
    def self.properties : Hash(String, JSON::Any)
      @@builder.properties
    end

    # The names of required properties, in declaration order.
    def self.required_properties : Array(String)
      @@builder.required
    end

    # Override the schema name used in the output envelope.
    def self.schema_name(name : String) : Nil
      @@schema_name = name
    end

    def self.schema_name : String?
      @@schema_name
    end

    # Override the schema-level description.
    def self.description(value : String) : Nil
      @@description = value
    end

    def self.description : String?
      @@description
    end

    # Whether the object permits properties beyond those declared (default false).
    def self.additional_properties(value : Bool) : Nil
      @@additional_properties = value
    end

    def self.additional_properties : Bool
      @@additional_properties
    end

    # Whether strict mode is emitted (default true; `nil` omits the key).
    def self.strict(value : Bool?) : Nil
      @@strict = value
    end

    def self.strict : Bool?
      @@strict
    end

    # --- Primitive DSL (class-body) -----------------------------------------

    # `enum:` is a Crystal keyword, so it is declared with a quoted external name;
    # callers still write `string "x", enum: [...]`.
    def self.string(name : String, description : String? = nil, required : Bool = true,
                    "enum" enum_values : Array(String)? = nil, min_length : Int32? = nil,
                    max_length : Int32? = nil, pattern : String? = nil,
                    format : String? = nil, requires : Array(String)? = nil) : Nil
      @@builder.string(name, description: description, required: required, enum_values: enum_values,
        min_length: min_length, max_length: max_length, pattern: pattern, format: format)
      register_requires(name, requires)
    end

    def self.number(name : String, description : String? = nil, required : Bool = true,
                    minimum : Float64? = nil, maximum : Float64? = nil,
                    multiple_of : Float64? = nil, requires : Array(String)? = nil) : Nil
      @@builder.number(name, description: description, required: required,
        minimum: minimum, maximum: maximum, multiple_of: multiple_of)
      register_requires(name, requires)
    end

    def self.integer(name : String, description : String? = nil, required : Bool = true,
                     minimum : Int32? = nil, maximum : Int32? = nil,
                     multiple_of : Int32? = nil, requires : Array(String)? = nil) : Nil
      @@builder.integer(name, description: description, required: required,
        minimum: minimum, maximum: maximum, multiple_of: multiple_of)
      register_requires(name, requires)
    end

    def self.boolean(name : String, description : String? = nil, required : Bool = true,
                     requires : Array(String)? = nil) : Nil
      @@builder.boolean(name, description: description, required: required)
      register_requires(name, requires)
    end

    def self.null(name : String, description : String? = nil, required : Bool = true,
                  requires : Array(String)? = nil) : Nil
      @@builder.null(name, description: description, required: required)
      register_requires(name, requires)
    end

    # --- Complex DSL (class-body) -------------------------------------------

    # Nested object. Takes an explicit builder block (Crystal divergence).
    def self.object(name : String, description : String? = nil, required : Bool = true,
                    requires : Array(String)? = nil, &block : Builder ->) : Nil
      @@builder.object(name, description: description, required: required, &block)
      register_requires(name, requires)
    end

    # Array of primitives (`of: :string`) or of objects (via builder block).
    def self.array(name : String, description : String? = nil, required : Bool = true,
                   of : Symbol? = nil, min_items : Int32? = nil, max_items : Int32? = nil,
                   requires : Array(String)? = nil, &block : Builder ->) : Nil
      @@builder.array(name, description: description, required: required, of: of,
        min_items: min_items, max_items: max_items, &block)
      register_requires(name, requires)
    end

    # Array of primitives only (no item block).
    def self.array(name : String, description : String? = nil, required : Bool = true,
                   of : Symbol? = nil, min_items : Int32? = nil, max_items : Int32? = nil,
                   requires : Array(String)? = nil) : Nil
      @@builder.array(name, description: description, required: required, of: of,
        min_items: min_items, max_items: max_items)
      register_requires(name, requires)
    end

    # --- Composition DSL (class-body) ---------------------------------------

    # `any_of`: the value validates against AT LEAST ONE member schema. The block
    # receives a member builder; each `m.string` / `m.object { ... }` /
    # `m.reference(...)` appends an alternative to the `anyOf` list.
    def self.any_of(name : String, description : String? = nil, required : Bool = true,
                    requires : Array(String)? = nil, &block : MemberBuilder ->) : Nil
      @@builder.any_of(name, description: description, required: required, &block)
      register_requires(name, requires)
    end

    # `one_of`: the value validates against EXACTLY ONE member schema.
    def self.one_of(name : String, description : String? = nil, required : Bool = true,
                    requires : Array(String)? = nil, &block : MemberBuilder ->) : Nil
      @@builder.one_of(name, description: description, required: required, &block)
      register_requires(name, requires)
    end

    # `optional`: sugar for `any_of` whose members are the block's members plus a
    # trailing `null` (mirrors the Ruby gem). Always emitted as required so the
    # key must be present, but may be null.
    def self.optional(name : String, description : String? = nil, &block : MemberBuilder ->) : Nil
      @@builder.optional(name, description: description, &block)
    end

    # --- Definitions / references DSL (class-body) --------------------------

    # `define`: register a reusable named object schema under `$defs`. The block
    # builds the object's properties (and may itself use `reference`).
    def self.define(name : String, description : String? = nil, &block : Builder ->) : Nil
      nested = Builder.new
      block.call(nested)
      schema = {} of String => JSON::Any
      schema["type"] = JSON::Any.new("object")
      schema["properties"] = JSON::Any.new(nested.properties)
      schema["required"] = JSON::Any.new(nested.required.map { |req| JSON::Any.new(req) })
      schema["additionalProperties"] = JSON::Any.new(false)
      schema["description"] = JSON::Any.new(description) if description
      @@definitions[name] = JSON::Any.new(schema)
    end

    # The accumulated `$defs` definitions for this schema class.
    def self.definitions : Hash(String, JSON::Any)
      @@definitions
    end

    # `reference`: a `$ref` pointer. `reference(:root)` / `reference("#")` points
    # at the document root; any other name points at `#/$defs/<name>`.
    def self.reference(name : String) : Hash(String, JSON::Any)
      if name == "#" || name == "root"
        {"$ref" => JSON::Any.new("#")}
      else
        {"$ref" => JSON::Any.new("#/$defs/#{name}")}
      end
    end

    # --- Conditionals DSL (class-body) --------------------------------------

    # The accumulated `given` conditions (if/then[/else] fragments).
    def self.conditions : Array(Hash(String, JSON::Any))
      @@conditions
    end

    # The accumulated `requires:`/`dependent` dependencies (property => builder).
    def self.dependencies : Hash(String, ConditionalBuilder)
      @@dependencies
    end

    # Register a `requires:` dependency: when `property` is present the listed
    # fields are required (emitted as `dependentRequired`). Mirrors the Ruby
    # `add_property(..., requires:)` path. No-op when `fields` is nil/empty.
    protected def self.register_requires(property : String, fields : Array(String)?) : Nil
      return if fields.nil? || fields.empty?
      builder = ConditionalBuilder.new
      builder.requires(fields)
      @@dependencies[property] = builder
    end

    # `dependent(property) { |b| ... }`: a schema-level dependency. When
    # `property` is present, the block's `requires`/`validates` constraints
    # apply. Emitted as `dependentRequired` (requires-only) or `dependentSchemas`.
    def self.dependent(property : String, &block : ConditionalBuilder ->) : Nil
      builder = ConditionalBuilder.new
      block.call(builder)
      @@dependencies[property] = builder
    end

    # `given(conditions) { |c| ... }`: an if/then[/else] conditional. The
    # `conditions` map is property name => the value that must match (coerced
    # like the Ruby `coerce_condition`: an Array becomes `enum`, a Hash is used
    # verbatim, anything else becomes `const`). The block's `c.requires` /
    # `c.validates` build the `then`; `c.otherwise { |o| ... }` builds the
    # `else`. Raises when `conditions` is empty (mirrors Ruby's ArgumentError).
    def self.given(conditions : Hash(String, JSON::Any), &block : ConditionalContext ->) : Nil
      raise InvalidSchemaError.new("given requires at least one property condition") if conditions.empty?

      if_props = {} of String => JSON::Any
      required = [] of JSON::Any
      conditions.each do |prop, value|
        if_props[prop] = coerce_condition(value)
        required << JSON::Any.new(prop)
      end
      if_schema = {} of String => JSON::Any
      if_schema["properties"] = JSON::Any.new(if_props)
      if_schema["required"] = JSON::Any.new(required)

      then_builder = ConditionalBuilder.new
      else_builder = ConditionalBuilder.new
      context = ConditionalContext.new(then_builder, else_builder)
      block.call(context)

      condition = {} of String => JSON::Any
      condition["if"] = JSON::Any.new(if_schema)
      condition["then"] = JSON::Any.new(then_builder.to_schema)
      condition["else"] = JSON::Any.new(else_builder.to_schema) unless else_builder.empty?

      @@conditions << condition
    end

    # Coerce a `given` condition value into a JSON-Schema constraint fragment,
    # mirroring Ruby's `coerce_condition`. Array => `{enum: ...}`, a hash (passed
    # as a `JSON::Any` object) => used verbatim, otherwise => `{const: value}`.
    private def self.coerce_condition(value : JSON::Any) : JSON::Any
      if arr = value.as_a?
        JSON::Any.new({"enum" => JSON::Any.new(arr)})
      elsif value.as_h?
        value
      else
        JSON::Any.new({"const" => value})
      end
    end

    # Merge `given` conditions and `requires:`/`dependent` dependencies into the
    # produced schema hash. Faithful port of `Conditionals#merge_conditions`:
    # a single condition is merged inline, several wrap in `allOf`; dependencies
    # with only `requires` go to `dependentRequired`, others to `dependentSchemas`.
    protected def self.merge_conditions(schema : Hash(String, JSON::Any)) : Nil
      if conditions.size == 1
        conditions.first.each { |key, value| schema[key] = value }
      elsif conditions.size > 1
        schema["allOf"] = JSON::Any.new(conditions.map { |cond| JSON::Any.new(cond) })
      end

      unless dependencies.empty?
        dependent_required = {} of String => JSON::Any
        dependent_schemas = {} of String => JSON::Any

        dependencies.each do |property, builder|
          if builder.validations_empty?
            dependent_required[property] =
              JSON::Any.new(builder.required_fields.map { |field| JSON::Any.new(field) })
          else
            dependent_schemas[property] = JSON::Any.new(builder.to_schema)
          end
        end

        schema["dependentRequired"] = JSON::Any.new(dependent_required) unless dependent_required.empty?
        schema["dependentSchemas"] = JSON::Any.new(dependent_schemas) unless dependent_schemas.empty?
      end
    end

    # --- Validation ----------------------------------------------------------

    # Run structural validation (currently: circular-reference detection over
    # `$defs`). Raises `ValidationError` on a cycle. Mirrors `validator.rb`.
    def self.validate! : Nil
      Validator.new(definitions).validate!
    end

    def self.valid? : Bool
      Validator.new(definitions).valid?
    end

    # --- Instance side -------------------------------------------------------

    getter name : String
    getter instance_description : String?

    def initialize(name : String? = nil, description : String? = nil)
      @name = name || self.class.schema_name || self.class.name
      @instance_description = description
    end

    # Run structural validation for this schema (delegates to the class). Mirrors
    # the Ruby gem's instance `validate!` / `valid?`.
    def validate! : Nil
      self.class.validate!
    end

    def valid? : Bool
      self.class.valid?
    end

    # Produce the gem's output envelope as `Hash(String, JSON::Any)`.
    #
    # As in the Ruby gem, this validates the schema first (raising on a circular
    # `$ref`) and emits `$defs` when any definitions are present.
    #
    # NOTE (still deferred): conditional (`allOf`/`dependent*`) merging is not
    # yet ported, so that block is omitted from the output.
    def to_json_schema : Hash(String, JSON::Any)
      validate!

      schema = {} of String => JSON::Any
      schema["type"] = JSON::Any.new("object")
      schema["properties"] = JSON::Any.new(self.class.properties)
      schema["required"] = JSON::Any.new(
        self.class.required_properties.map { |req| JSON::Any.new(req) }
      )
      schema["additionalProperties"] = JSON::Any.new(self.class.additional_properties)
      if s = self.class.strict
        schema["strict"] = JSON::Any.new(s)
      end
      unless self.class.definitions.empty?
        schema["$defs"] = JSON::Any.new(self.class.definitions)
      end

      self.class.merge_conditions(schema)

      result = {} of String => JSON::Any
      result["name"] = JSON::Any.new(@name)
      desc = @instance_description || self.class.description
      result["description"] = desc ? JSON::Any.new(desc) : JSON::Any.new(nil)
      result["schema"] = JSON::Any.new(schema)
      result
    end

    def to_json(*_args) : String
      to_json_schema.to_json
    end

    # Builds property hashes for a schema scope (the class body, or a nested
    # object / array-item). Each `object`/`array` block receives a fresh Builder.
    class Builder
      getter properties : Hash(String, JSON::Any)
      getter required : Array(String)

      def initialize
        @properties = {} of String => JSON::Any
        @required = [] of String
      end

      def string(name : String, description : String? = nil, required : Bool = true,
                 enum_values : Array(String)? = nil, min_length : Int32? = nil,
                 max_length : Int32? = nil, pattern : String? = nil,
                 format : String? = nil) : Nil
        h = {"type" => JSON::Any.new("string")} of String => JSON::Any
        h["description"] = JSON::Any.new(description) if description
        h["enum"] = JSON::Any.new(enum_values.map { |e| JSON::Any.new(e) }) if enum_values
        h["minLength"] = JSON::Any.new(min_length.to_i64) if min_length
        h["maxLength"] = JSON::Any.new(max_length.to_i64) if max_length
        h["pattern"] = JSON::Any.new(pattern) if pattern
        h["format"] = JSON::Any.new(format) if format
        add(name, h, required)
      end

      def number(name : String, description : String? = nil, required : Bool = true,
                 minimum : Float64? = nil, maximum : Float64? = nil,
                 multiple_of : Float64? = nil) : Nil
        h = {"type" => JSON::Any.new("number")} of String => JSON::Any
        h["description"] = JSON::Any.new(description) if description
        h["minimum"] = numeric_constraint(minimum) if minimum
        h["maximum"] = numeric_constraint(maximum) if maximum
        h["multipleOf"] = numeric_constraint(multiple_of) if multiple_of
        add(name, h, required)
      end

      def integer(name : String, description : String? = nil, required : Bool = true,
                  minimum : Int32? = nil, maximum : Int32? = nil,
                  multiple_of : Int32? = nil) : Nil
        h = {"type" => JSON::Any.new("integer")} of String => JSON::Any
        h["description"] = JSON::Any.new(description) if description
        h["minimum"] = JSON::Any.new(minimum.to_i64) if minimum
        h["maximum"] = JSON::Any.new(maximum.to_i64) if maximum
        h["multipleOf"] = JSON::Any.new(multiple_of.to_i64) if multiple_of
        add(name, h, required)
      end

      def boolean(name : String, description : String? = nil, required : Bool = true) : Nil
        h = {"type" => JSON::Any.new("boolean")} of String => JSON::Any
        h["description"] = JSON::Any.new(description) if description
        add(name, h, required)
      end

      def null(name : String, description : String? = nil, required : Bool = true) : Nil
        h = {"type" => JSON::Any.new("null")} of String => JSON::Any
        h["description"] = JSON::Any.new(description) if description
        add(name, h, required)
      end

      # Nested object via an explicit builder block (Crystal divergence — see the
      # class docs). When called with no name from an array item, returns the
      # inline object schema instead of adding a property.
      def object(name : String, description : String? = nil, required : Bool = true,
                 &block : Builder ->) : Nil
        add(name, object_schema(description, &block), required)
      end

      # Build an inline object schema (used for array-of-object items).
      def object(description : String? = nil, &block : Builder ->) : Nil
        @items = object_schema(description, &block)
      end

      # Array of primitives or of objects. With a block, the block builds the
      # single item schema (call `item.object { ... }` or `item.string`).
      def array(name : String, description : String? = nil, required : Bool = true,
                of : Symbol? = nil, min_items : Int32? = nil, max_items : Int32? = nil,
                &block : Builder ->) : Nil
        item_builder = Builder.new
        block.call(item_builder)
        items = item_builder.taken_item
        raise InvalidSchemaError.new("array '#{name}' block did not produce an item schema") unless items
        add(name, array_schema(items, description, min_items, max_items), required)
      end

      # Array of primitives via `of:` (no block).
      def array(name : String, description : String? = nil, required : Bool = true,
                of : Symbol? = nil, min_items : Int32? = nil, max_items : Int32? = nil) : Nil
        raise InvalidSchemaError.new("array '#{name}' requires `of:` or a block") unless of
        items = primitive_schema(of)
        add(name, array_schema(items, description, min_items, max_items), required)
      end

      # --- Composition -------------------------------------------------------

      # `any_of`: collect member schemas from the block into an `anyOf` list.
      def any_of(name : String, description : String? = nil, required : Bool = true,
                 &block : MemberBuilder ->) : Nil
        add(name, composition_schema("anyOf", description, &block), required)
      end

      # `one_of`: collect member schemas from the block into a `oneOf` list.
      def one_of(name : String, description : String? = nil, required : Bool = true,
                 &block : MemberBuilder ->) : Nil
        add(name, composition_schema("oneOf", description, &block), required)
      end

      # `optional`: `anyOf` of the block's members plus a trailing `null` member.
      def optional(name : String, description : String? = nil, &block : MemberBuilder ->) : Nil
        add(name, composition_schema("anyOf", description) do |member|
          block.call(member)
          member.null
        end, required: true)
      end

      private def composition_schema(key : String, description : String?,
                                     &block : MemberBuilder ->) : Hash(String, JSON::Any)
        member = MemberBuilder.new
        block.call(member)
        members = member.members
        raise InvalidSchemaError.new("#{key} block did not produce any member schemas") if members.empty?
        h = {} of String => JSON::Any
        h["description"] = JSON::Any.new(description) if description
        h[key] = JSON::Any.new(members.map { |schema| JSON::Any.new(schema) })
        h
      end

      # The item schema captured by an array-item block (`item.object`/`item.string`).
      @items : Hash(String, JSON::Any)? = nil

      def taken_item : Hash(String, JSON::Any)?
        @items
      end

      # Used by array-item blocks to capture a primitive item schema.
      {% for prim in %w[string integer number boolean null] %}
        def {{prim.id}} : Nil
          @items = primitive_schema(:{{prim.id}})
        end
      {% end %}

      private def object_schema(description : String?, &block : Builder ->) : Hash(String, JSON::Any)
        nested = Builder.new
        block.call(nested)
        h = {"type" => JSON::Any.new("object")} of String => JSON::Any
        h["properties"] = JSON::Any.new(nested.properties)
        h["required"] = JSON::Any.new(nested.required.map { |req| JSON::Any.new(req) })
        h["additionalProperties"] = JSON::Any.new(false)
        h["description"] = JSON::Any.new(description) if description
        h
      end

      private def array_schema(items : Hash(String, JSON::Any), description : String?,
                               min_items : Int32?, max_items : Int32?) : Hash(String, JSON::Any)
        h = {"type" => JSON::Any.new("array")} of String => JSON::Any
        h["description"] = JSON::Any.new(description) if description
        h["items"] = JSON::Any.new(items)
        h["minItems"] = JSON::Any.new(min_items.to_i64) if min_items
        h["maxItems"] = JSON::Any.new(max_items.to_i64) if max_items
        h
      end

      private def primitive_schema(type : Symbol) : Hash(String, JSON::Any)
        case type
        when :string, :number, :integer, :boolean, :null
          {"type" => JSON::Any.new(type.to_s)} of String => JSON::Any
        else
          raise InvalidArrayTypeError.new("Invalid array type: #{type.inspect}. " \
                                          "Must be a primitive type (:string, :number, :integer, :boolean, :null).")
        end
      end

      # ruby_llm-schema emits an integer-valued numeric constraint (e.g.
      # `minimum: 0`) as a JSON Integer, not a Float. A Float64 constraint that is
      # integer-valued therefore serializes as `0` rather than `0.0`; a genuinely
      # fractional value (e.g. `0.5`) stays a Float.
      private def numeric_constraint(value : Float64) : JSON::Any
        if value.finite? && value == value.to_i64
          JSON::Any.new(value.to_i64)
        else
          JSON::Any.new(value)
        end
      end

      private def add(name : String, definition : Hash(String, JSON::Any), required : Bool) : Nil
        @properties[name] = JSON::Any.new(definition)
        if required
          @required << name unless @required.includes?(name)
        else
          @required.delete(name)
        end
      end
    end

    # Collects alternative member schemas for `any_of` / `one_of` / `optional`.
    #
    # Crystal divergence: the Ruby gem's `collect_schemas_from_block` runs the
    # block in an `instance_eval` context whose bare `string` / `object` / ...
    # calls each push a schema. Here the block takes an explicit member builder
    # (`|m|`) and each `m.string` / `m.object { ... }` / `m.reference(...)`
    # appends one alternative.
    class MemberBuilder
      getter members : Array(Hash(String, JSON::Any))

      def initialize
        @members = [] of Hash(String, JSON::Any)
        @scratch = Builder.new
      end

      # Primitive members. Names are irrelevant inside a composition, so these
      # take only constraint options (the produced schema has no property name).
      def string(description : String? = nil, enum_values : Array(String)? = nil,
                 min_length : Int32? = nil, max_length : Int32? = nil,
                 pattern : String? = nil, format : String? = nil) : Nil
        @scratch.string("__m", description: description, enum_values: enum_values,
          min_length: min_length, max_length: max_length, pattern: pattern, format: format)
        take_scratch
      end

      def number(description : String? = nil, minimum : Float64? = nil,
                 maximum : Float64? = nil, multiple_of : Float64? = nil) : Nil
        @scratch.number("__m", description: description, minimum: minimum,
          maximum: maximum, multiple_of: multiple_of)
        take_scratch
      end

      def integer(description : String? = nil, minimum : Int32? = nil,
                  maximum : Int32? = nil, multiple_of : Int32? = nil) : Nil
        @scratch.integer("__m", description: description, minimum: minimum,
          maximum: maximum, multiple_of: multiple_of)
        take_scratch
      end

      def boolean(description : String? = nil) : Nil
        @scratch.boolean("__m", description: description)
        take_scratch
      end

      def null(description : String? = nil) : Nil
        @scratch.null("__m", description: description)
        take_scratch
      end

      # Inline object member.
      def object(description : String? = nil, &block : Builder ->) : Nil
        @scratch.object("__m", description: description, &block)
        take_scratch
      end

      # Inline array member (primitives via `of:`, objects via the item block).
      def array(description : String? = nil, of : Symbol? = nil,
                min_items : Int32? = nil, max_items : Int32? = nil,
                &block : Builder ->) : Nil
        @scratch.array("__m", description: description, of: of,
          min_items: min_items, max_items: max_items, &block)
        take_scratch
      end

      def array(description : String? = nil, of : Symbol? = nil,
                min_items : Int32? = nil, max_items : Int32? = nil) : Nil
        @scratch.array("__m", description: description, of: of,
          min_items: min_items, max_items: max_items)
        take_scratch
      end

      # A `$ref` member pointing at a `$defs` entry (or the document root).
      def reference(name : String) : Nil
        if name == "#" || name == "root"
          @members << {"$ref" => JSON::Any.new("#")}
        else
          @members << {"$ref" => JSON::Any.new("#/$defs/#{name}")}
        end
      end

      # Move the just-built `__m` property out of the scratch builder and onto the
      # members list as a bare schema (stripping the synthetic property name).
      private def take_scratch : Nil
        prop = @scratch.properties["__m"]
        @members << prop.as_h.dup
        @scratch = Builder.new
      end
    end

    # Builds the `then`/`else` (and `dependent`) sub-schema fragments for the
    # conditionals DSL. Faithful port of `Conditionals::ConditionalBuilder`:
    # `requires` accumulates required field names; `validates` accumulates a
    # per-field constraint map. `to_schema` emits `{required, properties}`.
    #
    # Crystal divergence: `validates` values are `JSON::Any` (wire convention)
    # and the option set is passed via named args rather than a Ruby `**options`
    # splat — unknown options are a compile error rather than a runtime raise.
    class ConditionalBuilder
      @required = [] of String
      @validations = {} of String => JSON::Any

      # Mark fields as required when the condition holds.
      def requires(*fields : String) : Nil
        fields.each { |field| @required << field }
      end

      # :ditto: (Array form, used by the `requires:` keyword path.)
      def requires(fields : Array(String)) : Nil
        fields.each { |field| @required << field }
      end

      # Add a constraint set for `field`. Each non-nil option maps to its
      # JSON-Schema key (mirrors Ruby's `VALIDATES_KEY_MAP`). `not_value` becomes
      # `{"not" => {"const" => value}}`; `type` is stringified.
      def validates(field : String, type : String? = nil, const : JSON::Any? = nil,
                    "enum" enum_values : Array(JSON::Any)? = nil, not_value : JSON::Any? = nil,
                    min_length : Int32? = nil, max_length : Int32? = nil,
                    pattern : String? = nil, minimum : (Int32 | Float64)? = nil,
                    maximum : (Int32 | Float64)? = nil) : Nil
        constraints = {} of String => JSON::Any
        constraints["type"] = JSON::Any.new(type) if type
        constraints["const"] = const if const
        constraints["enum"] = JSON::Any.new(enum_values) if enum_values
        constraints["not"] = JSON::Any.new({"const" => not_value}) if not_value
        constraints["minLength"] = JSON::Any.new(min_length.to_i64) if min_length
        constraints["maxLength"] = JSON::Any.new(max_length.to_i64) if max_length
        constraints["pattern"] = JSON::Any.new(pattern) if pattern
        constraints["minimum"] = numeric(minimum) if minimum
        constraints["maximum"] = numeric(maximum) if maximum
        @validations[field] = JSON::Any.new(constraints)
      end

      # The fragment `{required: [...], properties: {...}}` (omitting empties).
      def to_schema : Hash(String, JSON::Any)
        schema = {} of String => JSON::Any
        schema["required"] = JSON::Any.new(@required.map { |req| JSON::Any.new(req) }) unless @required.empty?
        schema["properties"] = JSON::Any.new(@validations) unless @validations.empty?
        schema
      end

      def empty? : Bool
        @required.empty? && @validations.empty?
      end

      def required_fields : Array(String)
        @required.dup
      end

      def validations_empty? : Bool
        @validations.empty?
      end

      private def numeric(value : Int32 | Float64) : JSON::Any
        case value
        in Int32   then JSON::Any.new(value.to_i64)
        in Float64 then JSON::Any.new(value)
        end
      end
    end

    # The block context for `given` — splits `requires`/`validates` onto the
    # `then` builder and routes `otherwise { |o| ... }` to the `else` builder.
    # Faithful port of `Conditionals::ConditionalContext`.
    class ConditionalContext
      def initialize(@then_builder : ConditionalBuilder, @else_builder : ConditionalBuilder)
      end

      def requires(*fields : String) : Nil
        @then_builder.requires(*fields)
      end

      def validates(field : String, type : String? = nil, const : JSON::Any? = nil,
                    "enum" enum_values : Array(JSON::Any)? = nil, not_value : JSON::Any? = nil,
                    min_length : Int32? = nil, max_length : Int32? = nil,
                    pattern : String? = nil, minimum : (Int32 | Float64)? = nil,
                    maximum : (Int32 | Float64)? = nil) : Nil
        @then_builder.validates(field, type: type, const: const, enum: enum_values,
          not_value: not_value, min_length: min_length, max_length: max_length,
          pattern: pattern, minimum: minimum, maximum: maximum)
      end

      def otherwise(&block : ConditionalBuilder ->) : Nil
        block.call(@else_builder)
      end
    end

    # Structural validator, ported from `validator.rb`. Operates on the produced
    # `$defs` map and detects circular references via a 3-colour DFS.
    #
    # Crystal divergence: the Ruby validator is constructed from the schema class
    # and reads `@schema_class.definitions`; here it takes the already-produced
    # `definitions` hash (`Hash(String, JSON::Any)`) directly so it has no back
    # reference to class state.
    class Validator
      enum Mark
        White # unvisited
        Gray  # on the current DFS path
        Black # fully processed
      end

      def initialize(@definitions : Hash(String, JSON::Any))
      end

      def validate! : Nil
        validate_circular_references!
        # Future structural validations can be added here.
      end

      def valid? : Bool
        validate!
        true
      rescue ValidationError
        false
      end

      private def validate_circular_references! : Nil
        return if @definitions.empty?

        marks = {} of String => Mark
        @definitions.each_key do |node|
          visit(node, marks) if marks.fetch(node, Mark::White).white?
        end
      end

      private def visit(node : String, marks : Hash(String, Mark)) : Nil
        mark = marks.fetch(node, Mark::White)
        return if mark.black?
        raise ValidationError.new("Circular reference detected involving '#{node}'") if mark.gray?

        marks[node] = Mark::Gray

        if definition = @definitions[node]?
          if (props = definition.as_h?) && (properties = props["properties"]?)
            properties.as_h.each_value do |property|
              extract_references(property).each do |adjacent|
                visit(adjacent, marks)
              end
            end
          end
        end

        marks[node] = Mark::Black
      end

      # Recursively collect the `$defs` names referenced by a property schema.
      private def extract_references(property : JSON::Any) : Array(String)
        references = [] of String

        if hash = property.as_h?
          if ref = hash["$ref"]?
            if ref_str = ref.as_s?
              name = ref_str.split("/").last?
              references << name if name && name != "#" && !name.empty?
            end
          else
            hash.each_value do |value|
              references.concat(extract_references(value))
            end
          end
        elsif arr = property.as_a?
          arr.each do |item|
            references.concat(extract_references(item))
          end
        end

        references
      end
    end

    # --- Errors (ported from ruby_llm/schema/errors.rb) ----------------------

    # Base error for schema problems.
    class Error < Exception; end

    # Raised when an invalid array element type is requested.
    class InvalidArrayTypeError < Error; end

    # Raised when an invalid object type is requested.
    class InvalidObjectTypeError < Error; end

    # Raised when a schema definition is malformed.
    class InvalidSchemaError < Error; end

    # Raised when runtime validation fails (validator deferred).
    class ValidationError < Error; end
  end
end
