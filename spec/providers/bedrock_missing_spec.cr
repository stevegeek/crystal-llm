require "../spec_helper"
require "../../src/crystal_llm/providers/bedrock"
require "base64"

# Missing coverage for Bedrock provider behaviour that exists in src/ but was
# previously untested:
#
#   1. Bedrock::Models#supports_structured_output? truth table
#   2. Bedrock::Media document blocks (.docx, .txt, .pptx unsupported)
#   3. render_tool_result_content('') → placeholder via the render_messages path
#   4. render_payload / build_output_config schema edge-cases

# ---------------------------------------------------------------------------
# Helpers shared across suites
# ---------------------------------------------------------------------------

private def configured_bedrock_missing : CrystalLLM::Providers::Bedrock
  config = CrystalLLM::Configuration.new
  config.bedrock_api_key = "test"
  config.bedrock_secret_key = "test"
  config.bedrock_region = "us-east-1"
  CrystalLLM::Providers::Bedrock.new(config)
end

private def simple_model_missing : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(
    id: "anthropic.claude-3-sonnet-20240229-v1:0",
    name: "Claude 3 Sonnet",
    provider: "bedrock"
  )
end

# Build a small in-memory attachment with the given filename and bytes.
# No network access — bytes are supplied directly.
private def mem_attachment(filename : String, bytes : String) : CrystalLLM::Attachment
  io = IO::Memory.new(bytes.to_slice)
  CrystalLLM::Attachment.new(io, filename: filename)
end

# ---------------------------------------------------------------------------
# 1. supports_structured_output? truth table
# ---------------------------------------------------------------------------

describe "CrystalLLM::Providers::Bedrock#supports_structured_output?" do
  provider = configured_bedrock_missing

  # claude-4-5 variants — all true
  it "returns true for claude-haiku-4-5 (bare)" do
    provider.supports_structured_output?("anthropic.claude-haiku-4-5-20251001-v1:0").should be_true
  end

  it "returns true for claude-sonnet-4-5 (bare)" do
    provider.supports_structured_output?("anthropic.claude-sonnet-4-5-20250929-v1:0").should be_true
  end

  it "returns true for claude-opus-4-5 (bare)" do
    provider.supports_structured_output?("anthropic.claude-opus-4-5-20250514-v1:0").should be_true
  end

  # region-prefixed but still 4-5 — all true
  it "returns true for us. prefixed haiku-4-5" do
    provider.supports_structured_output?("us.anthropic.claude-haiku-4-5-20251001-v1:0").should be_true
  end

  it "returns true for eu. prefixed haiku-4-5" do
    provider.supports_structured_output?("eu.anthropic.claude-haiku-4-5-20251001-v1:0").should be_true
  end

  it "returns true for global. prefixed haiku-4-5" do
    provider.supports_structured_output?("global.anthropic.claude-haiku-4-5-20251001-v1:0").should be_true
  end

  # major > 4 — true (us.opus-4-6)
  it "returns true for claude-opus-4-6 (major > 4)" do
    provider.supports_structured_output?("us.anthropic.claude-opus-4-6-v1").should be_true
  end

  # claude-4 without minor >=5 — false
  it "returns false for claude-opus-4-20250514 (minor 0, < 5)" do
    provider.supports_structured_output?("anthropic.claude-opus-4-20250514-v1:0").should be_false
  end

  # claude-3-5 — looks like 4-5 but isn't — false (major 3)
  it "returns false for claude-3-5-sonnet (major 3, minor 5 — but major must be >=4)" do
    provider.supports_structured_output?("anthropic.claude-3-5-sonnet-20241022-v2:0").should be_false
  end

  # Amazon Nova — false
  it "returns false for amazon nova" do
    provider.supports_structured_output?("amazon.nova-2-lite-v1:0").should be_false
  end

  # nil — false
  it "returns false for nil" do
    provider.supports_structured_output?(nil).should be_false
  end
end

# ---------------------------------------------------------------------------
# 2. Bedrock Media – document blocks
# ---------------------------------------------------------------------------

describe CrystalLLM::Providers::Bedrock::Media do
  describe "render_attachment document blocks" do
    it "renders a .docx attachment as a Bedrock document block with format 'docx'" do
      bytes = "docx bytes"
      attachment = mem_attachment("proposal.docx", bytes)
      attachment.type.should eq(:document)

      used = {} of String => Int32
      block = CrystalLLM::Providers::Bedrock::Media.render_attachment(attachment, used).as_h

      block.has_key?("document").should be_true
      doc = block["document"].as_h
      doc["format"].as_s.should eq("docx")
      doc["name"].as_s.should eq("proposal")
      doc["source"].as_h["bytes"].as_s.should eq(Base64.strict_encode(bytes))
    end

    # ruby_llm 1.16.0 / 329cfe4f "Keep text attachments as text": text-typed
    # attachments (csv/txt/md/html/json — text? == true) used to be promoted to a
    # Bedrock `document` block when their extension ALSO happened to be a
    # supported document format; render_text_attachment now always renders text
    # attachments as an inline `{text: ...}` block instead. Direct mirror of
    # upstream's rewritten bedrock/media_spec.rb "keeps text file formats as text
    # blocks" example (which iterates the same extension list).
    it "keeps text file formats as text blocks (not promoted to a document block)" do
      %w[csv txt md html json].each do |extension|
        bytes = "plain text notes"
        attachment = mem_attachment("notes.#{extension}", bytes)
        attachment.type.should eq(:text)

        used = {} of String => Int32
        block = CrystalLLM::Providers::Bedrock::Media.render_attachment(attachment, used).as_h

        block.has_key?("text").should be_true
        block.has_key?("document").should be_false
        block["text"].as_s.should eq(attachment.for_llm)
      end
    end

    it "raises UnsupportedAttachmentError for .pptx (unsupported format)" do
      # pptx is a document type but NOT in Bedrock's SUPPORTED_DOCUMENT_FORMATS list
      bytes = "pptx bytes"
      attachment = mem_attachment("deck.pptx", bytes)
      # Confirm it IS classified as a document (not unknown)
      attachment.type.should eq(:document)

      used = {} of String => Int32
      expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        CrystalLLM::Providers::Bedrock::Media.render_attachment(attachment, used)
      end
    end

    it "raises UnsupportedAttachmentError for .pptx and the error message is non-nil" do
      bytes = "pptx bytes"
      attachment = mem_attachment("deck.pptx", bytes)
      used = {} of String => Int32

      ex = expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        CrystalLLM::Providers::Bedrock::Media.render_attachment(attachment, used)
      end
      ex.message.should_not be_nil
    end
  end
end

# ---------------------------------------------------------------------------
# 3. render_tool_result_content('') → placeholder, via render_messages
# ---------------------------------------------------------------------------
#
# render_tool_result_content is private; exercise it through render_payload /
# render_messages which are public.

describe "CrystalLLM::Providers::Bedrock tool-result content rendering" do
  it "emits {text: '(no output)'} placeholder for an empty-string tool result" do
    provider = configured_bedrock_missing

    # A minimal assistant message with a tool call, followed by a tool-result
    # message with empty-string content — exactly the empty-result case.
    tool_call = CrystalLLM::ToolCall.new(id: "tc_1", name: "run_query", arguments: {} of String => JSON::Any)
    assistant_msg = CrystalLLM::Message.new(
      role: CrystalLLM::Role::Assistant,
      content: nil,
      tool_calls: {"tc_1" => tool_call}
    )
    tool_result_msg = CrystalLLM::Message.new(
      role: CrystalLLM::Role::Tool,
      content: "",
      tool_call_id: "tc_1"
    )
    user_msg = CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "summarize")

    payload = provider.render_payload(
      [user_msg, assistant_msg, tool_result_msg],
      tools: {} of String => CrystalLLM::Tool,
      temperature: nil,
      model: simple_model_missing,
      stream: false
    )

    messages = payload["messages"].as_a
    # The tool-result is bundled into a user turn; find the one containing toolResult.
    tool_result_turn = messages.find! do |msg_any|
      content = msg_any.as_h["content"]?.try(&.as_a?)
      content && content.any? { |blk| blk.as_h?.try(&.has_key?("toolResult")) }
    end

    content_blocks = tool_result_turn.as_h["content"].as_a
    tool_result_block = content_blocks.find! { |blk| blk.as_h?.try(&.has_key?("toolResult")) }
    tool_result = tool_result_block.as_h["toolResult"].as_h
    inner_content = tool_result["content"].as_a

    inner_content.size.should eq(1)
    inner_content[0].as_h["text"].as_s.should eq("(no output)")
  end

  it "emits {text: '(no output)'} placeholder for a nil tool result" do
    provider = configured_bedrock_missing

    tool_call = CrystalLLM::ToolCall.new(id: "tc_2", name: "lookup", arguments: {} of String => JSON::Any)
    assistant_msg = CrystalLLM::Message.new(
      role: CrystalLLM::Role::Assistant,
      content: nil,
      tool_calls: {"tc_2" => tool_call}
    )
    tool_result_msg = CrystalLLM::Message.new(
      role: CrystalLLM::Role::Tool,
      content: nil,
      tool_call_id: "tc_2"
    )
    user_msg = CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "go")

    payload = provider.render_payload(
      [user_msg, assistant_msg, tool_result_msg],
      tools: {} of String => CrystalLLM::Tool,
      temperature: nil,
      model: simple_model_missing,
      stream: false
    )

    messages = payload["messages"].as_a
    tool_result_turn = messages.find! do |msg_any|
      content = msg_any.as_h["content"]?.try(&.as_a?)
      content && content.any? { |blk| blk.as_h?.try(&.has_key?("toolResult")) }
    end

    content_blocks = tool_result_turn.as_h["content"].as_a
    tool_result_block = content_blocks.find! { |blk| blk.as_h?.try(&.has_key?("toolResult")) }
    tool_result = tool_result_block.as_h["toolResult"].as_h
    inner_content = tool_result["content"].as_a

    inner_content.size.should eq(1)
    inner_content[0].as_h["text"].as_s.should eq("(no output)")
  end
end

# ---------------------------------------------------------------------------
# 4. render_payload / build_output_config – schema edge-cases
# ---------------------------------------------------------------------------

describe "CrystalLLM::Providers::Bedrock#build_output_config / render_payload schema" do
  it "strips 'strict' from the inner schema JSON string" do
    provider = configured_bedrock_missing
    schema = JSON.parse(%({"name":"person","schema":{"type":"object","strict":true,"properties":{}}}))

    payload = provider.render_payload(
      [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
      tools: {} of String => CrystalLLM::Tool,
      temperature: nil,
      model: simple_model_missing,
      stream: false,
      schema: schema
    )

    json_schema = payload["outputConfig"].as_h["textFormat"].as_h["structure"].as_h["jsonSchema"].as_h
    parsed = JSON.parse(json_schema["schema"].as_s)
    parsed.as_h.has_key?("strict").should be_false
    parsed.as_h["type"].as_s.should eq("object")
  end

  it "honors a custom schema name in outputConfig" do
    provider = configured_bedrock_missing
    schema = JSON.parse(%({"name":"PersonSchema","schema":{"type":"object","properties":{}}}))

    payload = provider.render_payload(
      [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
      tools: {} of String => CrystalLLM::Tool,
      temperature: nil,
      model: simple_model_missing,
      stream: false,
      schema: schema
    )

    json_schema = payload["outputConfig"].as_h["textFormat"].as_h["structure"].as_h["jsonSchema"].as_h
    json_schema["name"].as_s.should eq("PersonSchema")
    # The inner schema string must NOT contain the envelope keys
    inner_str = json_schema["schema"].as_s
    inner_str.includes?("PersonSchema").should be_false
    inner_str.includes?("\"name\"").should be_false
  end

  it "does not mutate the original schema object" do
    provider = configured_bedrock_missing
    original_json = %({"name":"response","schema":{"type":"object","strict":true,"properties":{}}})
    schema = JSON.parse(original_json)

    provider.render_payload(
      [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
      tools: {} of String => CrystalLLM::Tool,
      temperature: nil,
      model: simple_model_missing,
      stream: false,
      schema: schema
    )

    # The original schema should still have "strict" in its inner schema
    inner = schema.as_h["schema"].as_h
    inner.has_key?("strict").should be_true
    inner["strict"].as_bool.should be_true
  end

  it "omits outputConfig when schema is nil" do
    provider = configured_bedrock_missing

    payload = provider.render_payload(
      [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
      tools: {} of String => CrystalLLM::Tool,
      temperature: nil,
      model: simple_model_missing,
      stream: false,
      schema: nil
    )

    payload.has_key?("outputConfig").should be_false
  end

  it "returns nil from build_output_config when schema has no inner 'schema' key" do
    provider = configured_bedrock_missing
    # A schema envelope without the inner "schema" key — build_output_config returns nil.
    schema = JSON.parse(%({"name":"x"}))

    payload = provider.render_payload(
      [CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: "hi")],
      tools: {} of String => CrystalLLM::Tool,
      temperature: nil,
      model: simple_model_missing,
      stream: false,
      schema: schema
    )

    payload.has_key?("outputConfig").should be_false
  end
end
