require "../spec_helper"
require "../../src/crystal_llm/providers/gemini"

# Unit tests for the shared structured-output schema rewriter + version gate
# (Providers::GeminiSchema). Exercised by both the Gemini and VertexAI providers.

private def model_for(id : String) : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(id: id, name: id, provider: "gemini")
end

private def convert(schema : JSON::Any) : Hash(String, JSON::Any)
  converted = CrystalLLM::Providers::GeminiSchema.convert(schema)
  raise "expected a converted schema" if converted.nil?
  converted.as_h
end

describe CrystalLLM::Providers::GeminiSchema do
  describe ".convert (recursive rewrite)" do
    it "rewrites a nested object + array + enum + nullable schema to the Gemini shape" do
      schema = JSON.parse(<<-JSON)
      {
        "type": "object",
        "description": "A person",
        "propertyOrdering": ["name", "age", "tags", "address"],
        "properties": {
          "name": {"type": "string"},
          "age": {"type": "integer", "minimum": 0},
          "status": {"type": "string", "enum": ["active", "inactive"]},
          "tags": {
            "type": "array",
            "items": {"type": "string"},
            "minItems": 1
          },
          "nickname": {"anyOf": [{"type": "string"}, {"type": "null"}]},
          "address": {
            "type": "object",
            "properties": {
              "city": {"type": "string"},
              "zip": {"type": "string"}
            },
            "required": ["city"]
          }
        },
        "required": ["name", "age"]
      }
      JSON

      result = convert(schema)

      result["type"].as_s.should eq("OBJECT")
      result["description"].as_s.should eq("A person")
      result["propertyOrdering"].as_a.map(&.as_s).should eq(["name", "age", "tags", "address"])
      result["required"].as_a.map(&.as_s).should eq(["name", "age"])

      props = result["properties"].as_h
      props["name"].as_h["type"].as_s.should eq("STRING")

      age = props["age"].as_h
      age["type"].as_s.should eq("INTEGER")
      age["minimum"].as_i.should eq(0)

      status = props["status"].as_h
      status["type"].as_s.should eq("STRING")
      status["enum"].as_a.map(&.as_s).should eq(["active", "inactive"])

      tags = props["tags"].as_h
      tags["type"].as_s.should eq("ARRAY")
      tags["items"].as_h["type"].as_s.should eq("STRING")
      tags["minItems"].as_i.should eq(1)

      # anyOf [T, null] collapses to T with nullable: true
      nickname = props["nickname"].as_h
      nickname["type"].as_s.should eq("STRING")
      nickname["nullable"].as_bool.should be_true

      # nested object
      address = props["address"].as_h
      address["type"].as_s.should eq("OBJECT")
      address["required"].as_a.map(&.as_s).should eq(["city"])
      address["properties"].as_h["zip"].as_h["type"].as_s.should eq("STRING")
    end

    it "uppercases number / boolean and carries their allowed constraint keys" do
      schema = JSON.parse(<<-JSON)
      {
        "type": "object",
        "properties": {
          "score": {"type": "number", "minimum": 0, "maximum": 100, "multipleOf": 0.5},
          "flag": {"type": "boolean", "nullable": true}
        }
      }
      JSON
      props = convert(schema)["properties"].as_h

      score = props["score"].as_h
      score["type"].as_s.should eq("NUMBER")
      score["minimum"].as_i.should eq(0)
      score["maximum"].as_i.should eq(100)
      score["multipleOf"].as_f.should eq(0.5)

      flag = props["flag"].as_h
      flag["type"].as_s.should eq("BOOLEAN")
      flag["nullable"].as_bool.should be_true
    end

    it "drops an empty required and strips strict / additionalProperties" do
      schema = JSON.parse(<<-JSON)
      {
        "type": "object",
        "strict": true,
        "additionalProperties": false,
        "required": [],
        "properties": {"x": {"type": "string"}}
      }
      JSON
      result = convert(schema)
      result.has_key?("required").should be_false
      result.has_key?("strict").should be_false
      result.has_key?("additionalProperties").should be_false
    end

    it "unwraps a {schema: ...} envelope" do
      schema = JSON.parse(%({"name":"p","schema":{"type":"string"}}))
      result = convert(schema)
      result["type"].as_s.should eq("STRING")
    end

    it "defaults array items to STRING when items is absent" do
      schema = JSON.parse(%({"type":"array"}))
      result = convert(schema)
      result["type"].as_s.should eq("ARRAY")
      result["items"].as_h["type"].as_s.should eq("STRING")
    end

    it "treats an unknown type as STRING" do
      schema = JSON.parse(%({"type":"weird","enum":["a","b"]}))
      result = convert(schema)
      result["type"].as_s.should eq("STRING")
      result["enum"].as_a.map(&.as_s).should eq(["a", "b"])
    end
  end

  describe ".convert ($ref / $defs resolution)" do
    it "resolves a $ref into $defs and strips the definitions key" do
      schema = JSON.parse(<<-JSON)
      {
        "type": "object",
        "$defs": {
          "Address": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"]
          }
        },
        "properties": {
          "home": {"$ref": "#/$defs/Address"}
        },
        "required": ["home"]
      }
      JSON
      result = convert(schema)
      result.has_key?("$defs").should be_false

      home = result["properties"].as_h["home"].as_h
      home["type"].as_s.should eq("OBJECT")
      home["properties"].as_h["city"].as_h["type"].as_s.should eq("STRING")
      home["required"].as_a.map(&.as_s).should eq(["city"])
    end

    it "merges sibling overrides onto the referenced definition" do
      schema = JSON.parse(<<-JSON)
      {
        "definitions": {
          "Base": {"type": "string"}
        },
        "$ref": "#/definitions/Base",
        "description": "overridden"
      }
      JSON
      result = convert(schema)
      result["type"].as_s.should eq("STRING")
      result["description"].as_s.should eq("overridden")
    end

    it "falls through to STRING for an unresolvable $ref" do
      schema = JSON.parse(%({"$ref":"#/$defs/Missing"}))
      result = convert(schema)
      result["type"].as_s.should eq("STRING")
    end

    it "guards against a self-referential $ref cycle" do
      schema = JSON.parse(<<-JSON)
      {
        "type": "object",
        "$defs": {
          "Node": {
            "type": "object",
            "properties": {"next": {"$ref": "#/$defs/Node"}}
          }
        },
        "properties": {"root": {"$ref": "#/$defs/Node"}}
      }
      JSON
      result = convert(schema)
      root = result["properties"].as_h["root"].as_h
      root["type"].as_s.should eq("OBJECT")
      # the cyclic inner ref bottoms out as a default STRING schema
      nxt = root["properties"].as_h["next"].as_h
      nxt["type"].as_s.should eq("STRING")
    end
  end

  describe ".structured_output_config (version gate)" do
    it "uses responseSchema (rewritten) for a < 2.5 model" do
      schema = JSON.parse(%({"type":"object","properties":{"a":{"type":"string"}}}))
      config = CrystalLLM::Providers::GeminiSchema.structured_output_config(schema, model_for("gemini-2.0-flash"))

      config["responseMimeType"].as_s.should eq("application/json")
      config.has_key?("responseJsonSchema").should be_false
      config["responseSchema"].as_h["type"].as_s.should eq("OBJECT")
    end

    it "uses responseJsonSchema (cleaned raw) for a >= 2.5 model" do
      schema = JSON.parse(%({"schema":{"type":"object","strict":true,"properties":{"a":{"type":"string"}}}}))
      config = CrystalLLM::Providers::GeminiSchema.structured_output_config(schema, model_for("gemini-2.5-flash"))

      config["responseMimeType"].as_s.should eq("application/json")
      config.has_key?("responseSchema").should be_false
      rjs = config["responseJsonSchema"].as_h
      # raw (lowercase) types preserved, strict stripped
      rjs["type"].as_s.should eq("object")
      rjs.has_key?("strict").should be_false
      rjs["properties"].as_h["a"].as_h["type"].as_s.should eq("string")
    end
  end

  describe "GeminiVersion" do
    it "extracts the leading major.minor from candidate strings" do
      CrystalLLM::Providers::GeminiVersion.extract_version("gemini-2.5-flash").should eq({2, 5})
      CrystalLLM::Providers::GeminiVersion.extract_version("gemini-2.0-flash").should eq({2, 0})
      CrystalLLM::Providers::GeminiVersion.extract_version("flash").should be_nil
    end

    it "gates on >= 2.5" do
      CrystalLLM::Providers::GeminiVersion.response_json_schema_supported?(model_for("gemini-2.5-pro")).should be_true
      CrystalLLM::Providers::GeminiVersion.response_json_schema_supported?(model_for("gemini-2.0-flash")).should be_false
      CrystalLLM::Providers::GeminiVersion.response_json_schema_supported?(model_for("gemini-3.0-pro")).should be_true
    end

    it "falls back to metadata version / description when the id has no version" do
      m = CrystalLLM::Model::Info.build(
        id: "gemini-flash-latest",
        name: "Gemini Flash",
        provider: "gemini",
        metadata: {"version" => JSON::Any.new("2.5")}
      )
      CrystalLLM::Providers::GeminiVersion.response_json_schema_supported?(m).should be_true
    end
  end
end
