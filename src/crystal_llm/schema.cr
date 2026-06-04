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
  # == Deferred (faithful port, later phase) ==
  #
  # * The runtime validator (`validate!` / `valid?` / `Validator`).
  # * Conditionals: `any_of` / `one_of` / `requires` / `optional` / `given` /
  #   `dependent` and the `allOf` / `dependentRequired` / `dependentSchemas` output.
  # * `$defs` / references: `define` / `reference` and the `$ref` machinery.
  # These are noted at their call sites; they are not stubbed to fake behaviour.
  class Schema
    # Per-subclass DSL state. Class variables are isolated per subclass in
    # Crystal; `macro inherited` re-initializes them so each subclass starts clean.
    @@builder = Builder.new
    @@schema_name : String? = nil
    @@description : String? = nil
    @@additional_properties = false
    @@strict : Bool? = true

    macro inherited
      @@builder = Builder.new
      @@schema_name = nil
      @@description = nil
      @@additional_properties = false
      @@strict = true
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
                    format : String? = nil) : Nil
      @@builder.string(name, description: description, required: required, enum_values: enum_values,
        min_length: min_length, max_length: max_length, pattern: pattern, format: format)
    end

    def self.number(name : String, description : String? = nil, required : Bool = true,
                    minimum : Float64? = nil, maximum : Float64? = nil,
                    multiple_of : Float64? = nil) : Nil
      @@builder.number(name, description: description, required: required,
        minimum: minimum, maximum: maximum, multiple_of: multiple_of)
    end

    def self.integer(name : String, description : String? = nil, required : Bool = true,
                     minimum : Int32? = nil, maximum : Int32? = nil,
                     multiple_of : Int32? = nil) : Nil
      @@builder.integer(name, description: description, required: required,
        minimum: minimum, maximum: maximum, multiple_of: multiple_of)
    end

    def self.boolean(name : String, description : String? = nil, required : Bool = true) : Nil
      @@builder.boolean(name, description: description, required: required)
    end

    def self.null(name : String, description : String? = nil, required : Bool = true) : Nil
      @@builder.null(name, description: description, required: required)
    end

    # --- Complex DSL (class-body) -------------------------------------------

    # Nested object. Takes an explicit builder block (Crystal divergence).
    def self.object(name : String, description : String? = nil, required : Bool = true,
                    &block : Builder ->) : Nil
      @@builder.object(name, description: description, required: required, &block)
    end

    # Array of primitives (`of: :string`) or of objects (via builder block).
    def self.array(name : String, description : String? = nil, required : Bool = true,
                   of : Symbol? = nil, min_items : Int32? = nil, max_items : Int32? = nil,
                   &block : Builder ->) : Nil
      @@builder.array(name, description: description, required: required, of: of,
        min_items: min_items, max_items: max_items, &block)
    end

    # Array of primitives only (no item block).
    def self.array(name : String, description : String? = nil, required : Bool = true,
                   of : Symbol? = nil, min_items : Int32? = nil, max_items : Int32? = nil) : Nil
      @@builder.array(name, description: description, required: required, of: of,
        min_items: min_items, max_items: max_items)
    end

    # --- Instance side -------------------------------------------------------

    getter name : String
    getter instance_description : String?

    def initialize(name : String? = nil, description : String? = nil)
      @name = name || self.class.schema_name || self.class.name
      @instance_description = description
    end

    # Produce the gem's output envelope as `Hash(String, JSON::Any)`.
    #
    # NOTE (deferred): the Ruby gem calls `validate!` here first, and merges
    # conditional (`allOf`/`dependent*`) and `$defs` output. Those subsystems are
    # not yet ported, so this emits only the type/properties/required/strict core.
    def to_json_schema : Hash(String, JSON::Any)
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
