require "../spec_helper"
require "../../src/crystal_llm/providers/anthropic"

# Covers Anthropic::Content factory (ported from anthropic/content.rb) and
# Anthropic::Embeddings raise stubs (anthropic/embeddings.rb).

private def configured_anthropic_content : CrystalLLM::Providers::Anthropic
  config = CrystalLLM::Configuration.new
  config.anthropic_api_key = "test"
  CrystalLLM::Providers::Anthropic.new(config)
end

describe "CrystalLLM::Providers::Anthropic::Content" do
  describe ".build" do
    it "wraps a plain text string in a single text block" do
      raw = CrystalLLM::Providers::Anthropic::Content.build("Hello, world")
      raw.should be_a(CrystalLLM::Content::Raw)
      blocks = raw.value.as_a
      blocks.size.should eq(1)
      block = blocks[0].as_h
      block["type"].as_s.should eq("text")
      block["text"].as_s.should eq("Hello, world")
      block.has_key?("cache_control").should be_false
    end

    it "adds ephemeral cache_control when cache: true" do
      raw = CrystalLLM::Providers::Anthropic::Content.build("Cached text", cache: true)
      block = raw.value.as_a[0].as_h
      block["cache_control"].as_h["type"].as_s.should eq("ephemeral")
    end

    it "uses an explicit cache_control when provided" do
      control = JSON.parse(%({"type": "ephemeral"}))
      raw = CrystalLLM::Providers::Anthropic::Content.build("text", cache_control: control)
      block = raw.value.as_a[0].as_h
      block["cache_control"].as_h["type"].as_s.should eq("ephemeral")
    end

    it "passes a pre-built parts array through unchanged" do
      parts = [JSON.parse(%({"type":"text","text":"pre-built"}))]
      raw = CrystalLLM::Providers::Anthropic::Content.build(parts: parts)
      raw.value.as_a.size.should eq(1)
      raw.value.as_a[0].as_h["text"].as_s.should eq("pre-built")
    end

    it "raises ArgumentError when neither text nor parts is provided" do
      expect_raises(ArgumentError, /text or parts/) do
        CrystalLLM::Providers::Anthropic::Content.build
      end
    end

    it "merges extras into the text block" do
      extras = {"custom_key" => JSON::Any.new("custom_value")} of String => JSON::Any
      raw = CrystalLLM::Providers::Anthropic::Content.build("text", extras: extras)
      block = raw.value.as_a[0].as_h
      block["custom_key"].as_s.should eq("custom_value")
    end
  end
end

describe "CrystalLLM::Providers::Anthropic Embeddings" do
  it "embedding_url raises with clear message" do
    provider = configured_anthropic_content
    expect_raises(CrystalLLM::Error, /doesn't support embeddings/) do
      provider.embedding_url(model: "anything")
    end
  end

  it "render_embedding_payload raises with clear message" do
    provider = configured_anthropic_content
    expect_raises(CrystalLLM::Error, /doesn't support embeddings/) do
      provider.render_embedding_payload("text", model: "anything", dimensions: nil)
    end
  end

  it "parse_embedding_response raises with clear message" do
    provider = configured_anthropic_content
    response = Crest::Response.new(
      HTTP::Client::Response.new(200, body: "{}"),
      Crest::Request.new(:post, "http://example.test")
    )
    expect_raises(CrystalLLM::Error, /doesn't support embeddings/) do
      provider.parse_embedding_response(response, model: "anything", text: "hi")
    end
  end
end
