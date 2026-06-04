require "./spec_helper"
require "../src/crystal_llm/tool"

# Spec-only Tool subclasses, namespaced to avoid collisions with other specs.
module ToolSpecHelpers
  # A described tool with no params (zero-arg execute).
  class DescribedTool < CrystalLLM::Tool
    description "Does a thing"

    def execute : CrystalLLM::ToolResult
      "ok"
    end
  end

  # `desc` alias.
  class DescAliasTool < CrystalLLM::Tool
    desc "Aliased"

    def execute : CrystalLLM::ToolResult
      "ok"
    end
  end

  # Param with a description (the spec's `param :city, description: "City name"`).
  class ParamDescriptionTool < CrystalLLM::Tool
    param city : String, "City name", required: true # ameba:disable Lint/UselessAssign

    def execute(city : String) : CrystalLLM::ToolResult
      city
    end

    def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
      execute(city: args["city"].as_s)
    end
  end

  # name derivation: SampleTool -> "sample"
  class SampleTool < CrystalLLM::Tool
    def execute : CrystalLLM::ToolResult
      "ok"
    end
  end

  # name derivation without Tool suffix: AnotherSample -> "another_sample"
  class AnotherSample < CrystalLLM::Tool
    def execute : CrystalLLM::ToolResult
      "ok"
    end
  end

  # A tool with declared params + typed execute + dispatch wiring.
  class SearchTool < CrystalLLM::Tool
    description "Search"
    param query : String, "Search query", required: true # ameba:disable Lint/UselessAssign
    param limit : Int32, "Max results", required: false  # ameba:disable Lint/UselessAssign

    def execute(query : String, limit : Int32?) : CrystalLLM::ToolResult
      "q=#{query} limit=#{limit || 5}"
    end

    def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
      execute(query: args["query"].as_s, limit: args["limit"]?.try(&.as_i))
    end
  end

  # One required keyword, used for missing/unknown validation.
  class RequiredTool < CrystalLLM::Tool
    param questions : Array(String), "Questions", required: true # ameba:disable Lint/UselessAssign

    def execute(questions : Array(String)) : CrystalLLM::ToolResult
      questions.join(",")
    end

    def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
      execute(questions: args["questions"].as_a.map(&.as_s))
    end
  end

  # A tool that halts.
  class HaltingTool < CrystalLLM::Tool
    def execute : CrystalLLM::ToolResult
      halt("stop here")
    end
  end
end

describe CrystalLLM::Tool do
  describe ".description / .desc" do
    it "reads the description set via `description`" do
      ToolSpecHelpers::DescribedTool.description.should eq("Does a thing")
      ToolSpecHelpers::DescribedTool.new.description.should eq("Does a thing")
    end

    it "accepts `desc` as a shorter alias" do
      ToolSpecHelpers::DescAliasTool.description.should eq("Aliased")
    end
  end

  describe ".param" do
    it "records the description on the parameter" do
      param = ToolSpecHelpers::ParamDescriptionTool.parameters.find! { |decl| decl.name == "city" }
      param.description.should eq("City name")
    end
  end

  # Crystal has no `stub_const`, so the Ruby fixtures that set an *unqualified*
  # class name are exercised against `Tool.derive_name` directly. The instance
  # `#name` reflects Crystal's mandatory namespacing (a documented divergence).
  describe ".derive_name (ported name algorithm)" do
    it "converts class name to snake_case and removes the _tool suffix" do
      CrystalLLM::Tool.derive_name("SampleTool").should eq("sample")
    end

    it "handles class names without a Tool suffix" do
      CrystalLLM::Tool.derive_name("AnotherSample").should eq("another_sample")
    end

    it "strips :: into -- for a class in a module namespace" do
      CrystalLLM::Tool.derive_name("TestModule::SampleTool").should eq("test_module--sample")
    end

    it "inserts an underscore at an ACRONYMWord boundary" do
      CrystalLLM::Tool.derive_name("HTTPSampleTool").should eq("http_sample")
    end
  end

  describe "#name" do
    it "derives the snake_case name from the (namespaced) class name" do
      # ToolSpecHelpers::SampleTool -> tool_spec_helpers--sample
      ToolSpecHelpers::SampleTool.new.name.should eq("tool_spec_helpers--sample")
    end
  end

  describe "#params_schema" do
    it "builds an object schema from declared params" do
      ToolSpecHelpers::SearchTool.new.params_schema.should eq(
        {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "query" => JSON::Any.new({
              "type"        => JSON::Any.new("string"),
              "description" => JSON::Any.new("Search query"),
            } of String => JSON::Any),
            "limit" => JSON::Any.new({
              "type"        => JSON::Any.new("integer"),
              "description" => JSON::Any.new("Max results"),
            } of String => JSON::Any),
          } of String => JSON::Any),
          "required"             => JSON::Any.new([JSON::Any.new("query")]),
          "additionalProperties" => JSON::Any.new(false),
          "strict"               => JSON::Any.new(true),
        } of String => JSON::Any
      )
    end

    it "uses an empty object schema for tools without parameters" do
      ToolSpecHelpers::SampleTool.new.params_schema.should eq(
        {
          "type"                 => JSON::Any.new("object"),
          "properties"           => JSON::Any.new({} of String => JSON::Any),
          "required"             => JSON::Any.new([] of JSON::Any),
          "additionalProperties" => JSON::Any.new(false),
          "strict"               => JSON::Any.new(true),
        } of String => JSON::Any
      )
    end
  end

  describe "#call" do
    it "dispatches execute with extracted, coerced args" do
      result = ToolSpecHelpers::SearchTool.new.call({
        "query" => JSON::Any.new("cats"),
        "limit" => JSON::Any.new(3_i64),
      })
      result.should eq("q=cats limit=3")
    end

    it "returns an error hash for a missing required keyword" do
      result = ToolSpecHelpers::RequiredTool.new.call({} of String => JSON::Any)
      result.should eq(
        {"error" => JSON::Any.new("Invalid tool arguments: missing keyword: questions")}
      )
    end

    it "returns an error hash for an unknown keyword" do
      result = ToolSpecHelpers::RequiredTool.new.call({
        "questions" => JSON::Any.new([] of JSON::Any),
        "isOther"   => JSON::Any.new(true),
      })
      result.should eq(
        {"error" => JSON::Any.new("Invalid tool arguments: unknown keyword: isOther")}
      )
    end

    it "returns an unknown-keyword error for a no-param tool given args" do
      result = ToolSpecHelpers::SampleTool.new.call({"unexpected" => JSON::Any.new(true)})
      result.should eq(
        {"error" => JSON::Any.new("Invalid tool arguments: unknown keyword: unexpected")}
      )
    end
  end

  describe "Halt" do
    it "is returned by halt and stringifies to its content" do
      result = ToolSpecHelpers::HaltingTool.new.call({} of String => JSON::Any)
      result.should be_a(CrystalLLM::Tool::Halt)
      result.as(CrystalLLM::Tool::Halt).to_s.should eq("stop here")
    end
  end

  describe CrystalLLM::DynamicTool do
    it "builds a tool from runtime name/description/schema and a body block" do
      schema = {
        "type"       => JSON::Any.new("object"),
        "properties" => JSON::Any.new({
          "q" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
        } of String => JSON::Any),
      } of String => JSON::Any

      tool = CrystalLLM::DynamicTool.new("web_search", "Search the web", schema) do |args|
        "searched: #{args["q"].as_s}"
      end

      tool.name.should eq("web_search")
      tool.description.should eq("Search the web")
      tool.params_schema.should eq(schema)
      tool.call({"q" => JSON::Any.new("crystal")}).should eq("searched: crystal")
    end
  end
end
