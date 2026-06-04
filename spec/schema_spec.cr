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

  describe "per-subclass isolation" do
    it "keeps properties isolated between subclasses" do
      SchemaSpecHelpers::FlatPerson.properties.has_key?("title").should be_false
      SchemaSpecHelpers::WithNested.properties.has_key?("name").should be_false
      SchemaSpecHelpers::WithNested.properties.has_key?("title").should be_true
    end
  end
end
