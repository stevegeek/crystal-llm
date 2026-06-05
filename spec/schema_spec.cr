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

  describe "per-subclass isolation" do
    it "keeps properties isolated between subclasses" do
      SchemaSpecHelpers::FlatPerson.properties.has_key?("title").should be_false
      SchemaSpecHelpers::WithNested.properties.has_key?("name").should be_false
      SchemaSpecHelpers::WithNested.properties.has_key?("title").should be_true
    end
  end
end
