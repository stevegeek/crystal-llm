require "./spec_helper"
require "../src/crystal_llm/schema"

# Spec-only schema subclasses, namespaced to avoid collisions with other specs.
module SchemaSpecHelpers
  class FlatPerson < CrystalLLM::Schema
    string "name", description: "Full name"
    integer "age", required: false, minimum: 0, maximum: 120
    number "score", minimum: 0.0
    boolean "active"
    string "status", enum: ["a", "b", "c"]
    null "deleted_at", required: false
  end

  class WithNested < CrystalLLM::Schema
    string "title"
    object "address", description: "Mailing address" do |obj|
      obj.string "city"
      obj.string "zip", required: false
    end
  end

  class WithArrays < CrystalLLM::Schema
    array "tags", of: :string, description: "Tag list"
    array "people", min_items: 1 do |item|
      item.object do |obj|
        obj.string "name"
      end
    end
  end

  # Number constraints that mix integer-valued (0, 100) and fractional (0.5)
  # bounds — to assert the parity serialization (integer-valued → Integer).
  class NumberConstraints < CrystalLLM::Schema
    number "ratio", minimum: 0.0, maximum: 100.0, multiple_of: 0.5
  end

  # Composition: any_of / one_of / optional.
  class WithComposition < CrystalLLM::Schema
    any_of "id", description: "string or int id" do |member|
      member.string
      member.integer
    end

    one_of "shape" do |member|
      member.object do |obj|
        obj.string "kind"
      end
      member.string enum_values: ["none"]
    end

    optional "nickname" do |member|
      member.string
    end
  end

  # $defs + reference, with a composition member that references a definition.
  class WithDefs < CrystalLLM::Schema
    define "address" do |defn|
      defn.string "city"
      defn.string "zip", required: false
    end

    any_of "home" do |member|
      member.reference "address"
      member.null
    end
  end

  # `requires:` on a property -> dependentRequired. A single `given` -> inline
  # if/then/else. A `dependent` with `validates` -> dependentSchemas.
  class WithConditionals < CrystalLLM::Schema
    string "billing_type", enum: ["card", "invoice"]
    # When `credit_card` is present, `cvv` and `expiry` must also be present.
    string "credit_card", required: false, requires: ["cvv", "expiry"]
    string "cvv", required: false
    string "expiry", required: false
    string "po_number", required: false

    given({"billing_type" => JSON::Any.new("invoice")}) do |cond|
      cond.requires "po_number"
      cond.validates "po_number", type: "string", min_length: 3
      cond.otherwise do |els|
        els.requires "credit_card"
      end
    end

    # A dependent with validations -> dependentSchemas.
    dependent "cvv" do |dep|
      dep.requires "credit_card"
      dep.validates "cvv", type: "string", pattern: "^[0-9]{3}$"
    end
  end

  # Two `given` blocks -> wrapped in `allOf`.
  class TwoGivens < CrystalLLM::Schema
    string "country"
    string "state", required: false
    string "postal_code", required: false

    given({"country" => JSON::Any.new("US")}) do |cond|
      cond.requires "state"
    end

    given({"country" => JSON::Any.new("CA")}) do |cond|
      cond.requires "postal_code"
    end
  end

  # An Array `given`-value is coerced into an `enum` constraint.
  class EnumGiven < CrystalLLM::Schema
    string "plan"
    string "seats", required: false

    given({"plan" => JSON::Any.new([JSON::Any.new("pro"), JSON::Any.new("team")])}) do |cond|
      cond.requires "seats"
    end
  end

  # Used to exercise the empty-`given` guard at call time (not class-body time,
  # which would abort program init).
  class EmptyGiven < CrystalLLM::Schema
    string "x"
  end

  # A self-referential (cyclic) $defs graph: node -> node, to exercise the
  # validator's circular-reference detection.
  class CyclicDefs < CrystalLLM::Schema
    define "node" do |defn|
      defn.any_of "next" do |member|
        member.reference "node"
        member.null
      end
    end
  end

  # `strict false` must still emit `"strict": false` (regression: a truthiness
  # check would drop the key because `false` is falsy).
  class StrictFalse < CrystalLLM::Schema
    strict false
    string "x"
  end

  # `strict nil` omits the key entirely (mirrors Ruby's `unless strict.nil?`).
  class StrictNil < CrystalLLM::Schema
    strict nil
    string "x"
  end

  # `additional_properties true` must be emittable as `additionalProperties: true`.
  class AdditionalPropsTrue < CrystalLLM::Schema
    additional_properties true
    string "x"
  end

  # Used to exercise the invalid-`of:` array-type guard at call time (a class-body
  # raise would abort program init).
  class BadArray < CrystalLLM::Schema
    string "x"
  end
end

describe CrystalLLM::Schema do
  describe "#to_json_schema" do
    it "produces the gem shape for a flat schema" do
      result = SchemaSpecHelpers::FlatPerson.new("person", description: "A person").to_json_schema

      result["name"].should eq(JSON::Any.new("person"))
      result["description"].should eq(JSON::Any.new("A person"))

      schema = result["schema"].as_h
      schema["type"].should eq(JSON::Any.new("object"))
      schema["additionalProperties"].should eq(JSON::Any.new(false))
      schema["strict"].should eq(JSON::Any.new(true))

      props = schema["properties"].as_h
      props["name"].as_h["type"].should eq(JSON::Any.new("string"))
      props["name"].as_h["description"].should eq(JSON::Any.new("Full name"))
      props["age"].as_h["type"].should eq(JSON::Any.new("integer"))
      props["age"].as_h["minimum"].should eq(JSON::Any.new(0_i64))
      props["age"].as_h["maximum"].should eq(JSON::Any.new(120_i64))
      props["score"].as_h["type"].should eq(JSON::Any.new("number"))
      props["active"].as_h["type"].should eq(JSON::Any.new("boolean"))
      props["status"].as_h["enum"].as_a.map(&.as_s).should eq(["a", "b", "c"])
      props["deleted_at"].as_h["type"].should eq(JSON::Any.new("null"))

      required = schema["required"].as_a.map(&.as_s)
      required.should contain("name")
      required.should contain("score")
      required.should contain("active")
      required.should contain("status")
      required.should_not contain("age")
      required.should_not contain("deleted_at")
    end

    it "produces a nested object schema" do
      schema = SchemaSpecHelpers::WithNested.new("nested").to_json_schema["schema"].as_h
      addr = schema["properties"].as_h["address"].as_h

      addr["type"].should eq(JSON::Any.new("object"))
      addr["description"].should eq(JSON::Any.new("Mailing address"))
      addr["additionalProperties"].should eq(JSON::Any.new(false))

      addr_props = addr["properties"].as_h
      addr_props["city"].as_h["type"].should eq(JSON::Any.new("string"))
      addr_props["zip"].as_h["type"].should eq(JSON::Any.new("string"))

      addr["required"].as_a.map(&.as_s).should eq(["city"])
    end

    it "produces array schemas for primitive and object items" do
      schema = SchemaSpecHelpers::WithArrays.new("arr").to_json_schema["schema"].as_h
      props = schema["properties"].as_h

      tags = props["tags"].as_h
      tags["type"].should eq(JSON::Any.new("array"))
      tags["description"].should eq(JSON::Any.new("Tag list"))
      tags["items"].as_h["type"].should eq(JSON::Any.new("string"))

      people = props["people"].as_h
      people["type"].should eq(JSON::Any.new("array"))
      people["minItems"].should eq(JSON::Any.new(1_i64))
      items = people["items"].as_h
      items["type"].should eq(JSON::Any.new("object"))
      items["properties"].as_h["name"].as_h["type"].should eq(JSON::Any.new("string"))
    end

    it "falls back to the class name when no name is given" do
      result = SchemaSpecHelpers::FlatPerson.new.to_json_schema
      result["name"].as_s.should eq("SchemaSpecHelpers::FlatPerson")
    end

    it "serializes to a JSON string" do
      json = SchemaSpecHelpers::FlatPerson.new("person").to_json
      parsed = JSON.parse(json)
      parsed["schema"]["type"].as_s.should eq("object")
    end
  end

  # Regression (parity quick win d): ruby_llm-schema emits an integer-valued
  # numeric constraint as a JSON Integer (`0`), not a Float (`0.0`); a genuinely
  # fractional bound stays a Float.
  describe "number-field integer-valued constraints" do
    it "serializes integer-valued numeric constraints without a trailing .0" do
      ratio = SchemaSpecHelpers::NumberConstraints.new("nc")
        .to_json_schema["schema"].as_h["properties"].as_h["ratio"].as_h

      # integer-valued → JSON Integer (raw is Int64, renders as `0` / `100`)
      ratio["minimum"].raw.should be_a(Int64)
      ratio["minimum"].as_i.should eq(0)
      ratio["maximum"].as_i.should eq(100)
      # fractional → stays a Float
      ratio["multipleOf"].raw.should be_a(Float64)
      ratio["multipleOf"].as_f.should eq(0.5)

      json = SchemaSpecHelpers::NumberConstraints.new("nc").to_json
      json.should contain(%("minimum":0))
      json.should_not contain(%("minimum":0.0))
    end

    it "also applies to the existing number field's minimum" do
      score = SchemaSpecHelpers::FlatPerson.new("p")
        .to_json_schema["schema"].as_h["properties"].as_h["score"].as_h
      score["minimum"].raw.should be_a(Int64)
    end
  end

  describe "composition (any_of / one_of / optional)" do
    it "produces anyOf / oneOf member lists" do
      schema = SchemaSpecHelpers::WithComposition.new("c").to_json_schema["schema"].as_h
      props = schema["properties"].as_h

      id = props["id"].as_h
      id["description"].should eq(JSON::Any.new("string or int id"))
      id_members = id["anyOf"].as_a.map(&.as_h)
      id_members.map(&.["type"].as_s).should eq(["string", "integer"])

      shape = props["shape"].as_h
      shape_members = shape["oneOf"].as_a.map(&.as_h)
      shape_members[0]["type"].as_s.should eq("object")
      shape_members[0]["properties"].as_h["kind"].as_h["type"].as_s.should eq("string")
      shape_members[1]["type"].as_s.should eq("string")
      shape_members[1]["enum"].as_a.map(&.as_s).should eq(["none"])
    end

    it "appends a null member for optional" do
      schema = SchemaSpecHelpers::WithComposition.new("c").to_json_schema["schema"].as_h
      nickname = schema["properties"].as_h["nickname"].as_h
      members = nickname["anyOf"].as_a.map(&.as_h)
      members.map(&.["type"].as_s).should eq(["string", "null"])
      # optional keys are still required (present, but may be null)
      schema["required"].as_a.map(&.as_s).should contain("nickname")
    end
  end

  describe "$defs and reference" do
    it "emits $defs and a $ref into a composition member" do
      schema = SchemaSpecHelpers::WithDefs.new("d").to_json_schema["schema"].as_h

      defs = schema["$defs"].as_h
      defs.has_key?("address").should be_true
      addr = defs["address"].as_h
      addr["type"].as_s.should eq("object")
      addr["properties"].as_h["city"].as_h["type"].as_s.should eq("string")
      addr["required"].as_a.map(&.as_s).should eq(["city"])

      home = schema["properties"].as_h["home"].as_h
      members = home["anyOf"].as_a.map(&.as_h)
      members[0]["$ref"].as_s.should eq("#/$defs/address")
      members[1]["type"].as_s.should eq("null")
    end

    it "valid? is true for a well-formed (non-cyclic) schema" do
      SchemaSpecHelpers::WithDefs.valid?.should be_true
      SchemaSpecHelpers::WithDefs.new("d").valid?.should be_true
    end
  end

  describe "validate! (circular references)" do
    it "raises ValidationError on a self-referential $defs cycle" do
      expect_raises(CrystalLLM::Schema::ValidationError, /Circular reference/) do
        SchemaSpecHelpers::CyclicDefs.validate!
      end
    end

    it "valid? is false for a cyclic schema" do
      SchemaSpecHelpers::CyclicDefs.valid?.should be_false
    end

    it "to_json_schema raises on a cyclic schema" do
      expect_raises(CrystalLLM::Schema::ValidationError) do
        SchemaSpecHelpers::CyclicDefs.new("x").to_json_schema
      end
    end
  end

  describe "conditionals (requires / given / dependent)" do
    it "emits dependentRequired for a `requires:` property and dependentSchemas for a validating dependent" do
      schema = SchemaSpecHelpers::WithConditionals.new("c").to_json_schema["schema"].as_h

      dep_req = schema["dependentRequired"].as_h
      dep_req["credit_card"].as_a.map(&.as_s).should eq(["cvv", "expiry"])
      # `cvv` has validations, so it goes to dependentSchemas, not dependentRequired.
      dep_req.has_key?("cvv").should be_false

      dep_schemas = schema["dependentSchemas"].as_h
      cvv = dep_schemas["cvv"].as_h
      cvv["required"].as_a.map(&.as_s).should eq(["credit_card"])
      cvv["properties"].as_h["cvv"].as_h["type"].as_s.should eq("string")
      cvv["properties"].as_h["cvv"].as_h["pattern"].as_s.should eq("^[0-9]{3}$")
    end

    it "merges a single `given` inline as if/then/else" do
      schema = SchemaSpecHelpers::WithConditionals.new("c").to_json_schema["schema"].as_h

      # single condition => inline keys, no allOf
      schema.has_key?("allOf").should be_false

      if_schema = schema["if"].as_h
      if_schema["properties"].as_h["billing_type"].as_h["const"].as_s.should eq("invoice")
      if_schema["required"].as_a.map(&.as_s).should eq(["billing_type"])

      then_schema = schema["then"].as_h
      then_schema["required"].as_a.map(&.as_s).should eq(["po_number"])
      po = then_schema["properties"].as_h["po_number"].as_h
      po["type"].as_s.should eq("string")
      po["minLength"].as_i.should eq(3)

      else_schema = schema["else"].as_h
      else_schema["required"].as_a.map(&.as_s).should eq(["credit_card"])
    end

    it "wraps multiple `given` blocks in allOf" do
      schema = SchemaSpecHelpers::TwoGivens.new("g").to_json_schema["schema"].as_h

      schema.has_key?("if").should be_false
      all_of = schema["allOf"].as_a.map(&.as_h)
      all_of.size.should eq(2)
      all_of[0]["if"].as_h["properties"].as_h["country"].as_h["const"].as_s.should eq("US")
      all_of[0]["then"].as_h["required"].as_a.map(&.as_s).should eq(["state"])
      all_of[1]["if"].as_h["properties"].as_h["country"].as_h["const"].as_s.should eq("CA")
      all_of[1]["then"].as_h["required"].as_a.map(&.as_s).should eq(["postal_code"])
    end

    it "coerces an Array given-value into an enum constraint" do
      schema = SchemaSpecHelpers::EnumGiven.new("e").to_json_schema["schema"].as_h
      cond = schema["if"].as_h["properties"].as_h["plan"].as_h
      cond["enum"].as_a.map(&.as_s).should eq(["pro", "team"])
    end

    it "raises when given has no conditions" do
      expect_raises(CrystalLLM::Schema::InvalidSchemaError, /at least one/) do
        SchemaSpecHelpers::EmptyGiven.given({} of String => JSON::Any) { |_c| }
      end
    end
  end

  # Parity with ruby_llm-schema's strict_spec.rb: `strict` is emitted unless nil,
  # so `false` must survive as `"strict": false` (regression — a truthy check
  # dropped it). `additional_properties true` must emit `true`.
  describe "strict / additionalProperties emission" do
    it "emits strict: false when set to false (does not drop the key)" do
      schema = SchemaSpecHelpers::StrictFalse.new("s").to_json_schema["schema"].as_h
      schema.has_key?("strict").should be_true
      schema["strict"].should eq(JSON::Any.new(false))

      json = SchemaSpecHelpers::StrictFalse.new("s").to_json
      json.should contain(%("strict":false))
    end

    it "omits strict from output when set to nil" do
      schema = SchemaSpecHelpers::StrictNil.new("s").to_json_schema["schema"].as_h
      schema.has_key?("strict").should be_false
    end

    it "emits additionalProperties: true when set to true" do
      schema = SchemaSpecHelpers::AdditionalPropsTrue.new("a").to_json_schema["schema"].as_h
      schema["additionalProperties"].should eq(JSON::Any.new(true))
    end
  end

  # Parity with ruby_llm-schema's error_handling_spec.rb: an invalid `of:` array
  # item type raises InvalidArrayTypeError with a descriptive message. Exercised
  # at call time so a class-body raise does not abort program init.
  describe "invalid array item type" do
    it "raises InvalidArrayTypeError with a descriptive message for a non-primitive `of:`" do
      expect_raises(CrystalLLM::Schema::InvalidArrayTypeError, /Invalid array type: :not_a_type.*primitive/) do
        SchemaSpecHelpers::BadArray.array("items", of: :not_a_type)
      end
    end
  end

  # Task 4: runtime `Schema.build` builder (recovers ruby_llm's `Schema.create`).
  describe ".build (runtime builder)" do
    it "produces the gem envelope from a runtime block, with nested object and array" do
      schema = CrystalLLM::Schema.build("person", description: "A person") do |sch|
        sch.string "city"
        sch.integer "age", required: false
        sch.object "addr" do |obj|
          obj.string "street"
          obj.string "zip", required: false
        end
        sch.array "tags", of: :string
      end

      result = schema.to_json_schema
      result["name"].should eq(JSON::Any.new("person"))
      result["description"].should eq(JSON::Any.new("A person"))

      inner = result["schema"].as_h
      inner["type"].should eq(JSON::Any.new("object"))
      inner["additionalProperties"].should eq(JSON::Any.new(false))
      inner["strict"].should eq(JSON::Any.new(true))

      props = inner["properties"].as_h
      props["city"].as_h["type"].should eq(JSON::Any.new("string"))
      props["age"].as_h["type"].should eq(JSON::Any.new("integer"))

      addr = props["addr"].as_h
      addr["type"].should eq(JSON::Any.new("object"))
      addr["properties"].as_h["street"].as_h["type"].should eq(JSON::Any.new("string"))
      addr["required"].as_a.map(&.as_s).should eq(["street"])

      tags = props["tags"].as_h
      tags["type"].should eq(JSON::Any.new("array"))
      tags["items"].as_h["type"].should eq(JSON::Any.new("string"))

      required = inner["required"].as_a.map(&.as_s)
      required.should contain("city")
      required.should contain("addr")
      required.should contain("tags")
      required.should_not contain("age")
    end

    it "serializes to a JSON string usable as a structured-output schema" do
      schema = CrystalLLM::Schema.build("answer") do |sch|
        sch.string "text"
      end
      parsed = JSON.parse(schema.to_json)
      parsed["name"].as_s.should eq("answer")
      parsed["schema"]["properties"]["text"]["type"].as_s.should eq("string")
    end

    it "honors strict nil (omits the key) and additional_properties true" do
      schema = CrystalLLM::Schema.build(strict: nil, additional_properties: true) do |sch|
        sch.string "x"
      end
      inner = schema.to_json_schema["schema"].as_h
      inner.has_key?("strict").should be_false
      inner["additionalProperties"].should eq(JSON::Any.new(true))
    end
  end

  describe "per-subclass isolation" do
    it "keeps properties isolated between subclasses" do
      SchemaSpecHelpers::FlatPerson.properties.has_key?("title").should be_false
      SchemaSpecHelpers::WithNested.properties.has_key?("name").should be_false
      SchemaSpecHelpers::WithNested.properties.has_key?("title").should be_true
    end
  end
end
