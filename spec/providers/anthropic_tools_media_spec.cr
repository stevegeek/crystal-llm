require "../spec_helper"
require "../../src/crystal_llm/providers/anthropic"

# Covers Anthropic::Tools wire-shape helpers and Anthropic::Media format_content
# for document attachments.  No network: all inputs are built in-memory.
#
# Mirrors:
#   ruby_llm-source/spec/ruby_llm/providers/anthropic/tools_spec.rb
#   ruby_llm-source/spec/ruby_llm/providers/anthropic/media_spec.rb

# ---------------------------------------------------------------------------
# Inline byte fixtures — no files fetched from disk or network
# ---------------------------------------------------------------------------

# "%PDF" magic sniffed as application/pdf by MimeType
PDF_MAGIC_TOOLS = "%PDF-1.4\n".to_slice

# A minimal valid docx (Office Open XML) is a ZIP; we only need a convincing
# filename so MimeType.for(name:) returns the correct MIME type.
DOCX_CONTENT_BYTES = "PK\x03\x04".to_slice

private def pdf_attachment : CrystalLLM::Attachment
  io = IO::Memory.new
  io.write(PDF_MAGIC_TOOLS)
  io.rewind
  CrystalLLM::Attachment.new(io, filename: "report.pdf")
end

private def docx_attachment : CrystalLLM::Attachment
  io = IO::Memory.new
  io.write(DOCX_CONTENT_BYTES)
  io.rewind
  CrystalLLM::Attachment.new(io, filename: "proposal.docx")
end

private def tool_call_message_with_content(content : String?) : CrystalLLM::Message
  tc = CrystalLLM::ToolCall.new(
    id: "tool_123",
    name: "test_tool",
    arguments: {"arg1" => JSON::Any.new("value1")} of String => JSON::Any
  )
  CrystalLLM::Message.new(
    role: CrystalLLM::Role::Assistant,
    content: content,
    tool_calls: {"tool_123" => tc}
  )
end

private def tool_result_message(content : String, tool_call_id : String = "tool_123") : CrystalLLM::Message
  CrystalLLM::Message.new(
    role: CrystalLLM::Role::Tool,
    content: content,
    tool_call_id: tool_call_id
  )
end

private def configured_anthropic_tools : CrystalLLM::Providers::Anthropic
  config = CrystalLLM::Configuration.new
  config.anthropic_api_key = "test"
  CrystalLLM::Providers::Anthropic.new(config)
end

private def claude_model_tools : CrystalLLM::Model::Info
  CrystalLLM::Model::Info.build(
    id: "claude-3-5-sonnet-20241022",
    name: "Claude 3.5 Sonnet",
    provider: "anthropic",
    max_output_tokens: 8192
  )
end

# ---------------------------------------------------------------------------
# Tools: format_tool_call_message (via format_message / render_payload)
# ---------------------------------------------------------------------------

describe "CrystalLLM::Providers::Anthropic::Tools format_tool_call_message" do
  it "emits role:assistant with a text block + tool_use block when content is non-empty" do
    provider = configured_anthropic_tools
    msg = tool_call_message_with_content("Some content")

    result = provider.format_message(msg, nil).as_h
    result["role"].as_s.should eq("assistant")
    blocks = result["content"].as_a
    blocks.size.should eq(2)

    blocks[0].as_h["type"].as_s.should eq("text")
    blocks[0].as_h["text"].as_s.should eq("Some content")

    tool_block = blocks[1].as_h
    tool_block["type"].as_s.should eq("tool_use")
    tool_block["id"].as_s.should eq("tool_123")
    tool_block["name"].as_s.should eq("test_tool")
    tool_block["input"].as_h["arg1"].as_s.should eq("value1")
  end

  it "omits the text block when content is nil (only tool_use block emitted)" do
    provider = configured_anthropic_tools
    msg = tool_call_message_with_content(nil)

    result = provider.format_message(msg, nil).as_h
    result["role"].as_s.should eq("assistant")
    blocks = result["content"].as_a
    blocks.size.should eq(1)
    blocks[0].as_h["type"].as_s.should eq("tool_use")
  end

  it "omits the text block when content is empty string (only tool_use block emitted)" do
    provider = configured_anthropic_tools
    msg = tool_call_message_with_content("")

    result = provider.format_message(msg, nil).as_h
    blocks = result["content"].as_a
    blocks.size.should eq(1)
    blocks[0].as_h["type"].as_s.should eq("tool_use")
  end

  it "emits 1 text block + N tool_use blocks for multiple tool calls" do
    tool_ids = {"tool_1", "tool_2", "tool_3"}
    tool_calls = {} of String => CrystalLLM::ToolCall
    tool_ids.each do |id|
      tool_calls[id] = CrystalLLM::ToolCall.new(
        id: id, name: "dice_roll", arguments: {} of String => JSON::Any
      )
    end
    msg = CrystalLLM::Message.new(
      role: CrystalLLM::Role::Assistant,
      content: "Rolling dice 3 times",
      tool_calls: tool_calls
    )

    provider = configured_anthropic_tools
    result = provider.format_message(msg, nil).as_h
    result["role"].as_s.should eq("assistant")
    blocks = result["content"].as_a

    # 1 text + 3 tool_use = 4 total
    blocks.size.should eq(4)
    blocks[0].as_h["type"].as_s.should eq("text")
    blocks[0].as_h["text"].as_s.should eq("Rolling dice 3 times")

    tool_use_blocks = blocks[1..]
    tool_use_blocks.all? { |blk| blk.as_h["type"].as_s == "tool_use" }.should be_true
    found_ids = tool_use_blocks.map(&.as_h.["id"].as_s).to_set
    found_ids.should eq(tool_ids.to_set)
    tool_use_blocks.all? { |blk| blk.as_h["name"].as_s == "dice_roll" }.should be_true
  end

  it "does NOT emit an empty text block when content is empty with multiple tool calls" do
    tool_calls = {
      "tool_1" => CrystalLLM::ToolCall.new(
        id: "tool_1", name: "dice_roll", arguments: {} of String => JSON::Any
      ),
    }
    msg = CrystalLLM::Message.new(
      role: CrystalLLM::Role::Assistant,
      content: "",
      tool_calls: tool_calls
    )

    provider = configured_anthropic_tools
    result = provider.format_message(msg, nil).as_h
    blocks = result["content"].as_a
    # Only the tool_use block — no text block
    blocks.size.should eq(1)
    blocks[0].as_h["type"].as_s.should eq("tool_use")
  end
end

# ---------------------------------------------------------------------------
# Tools: format_tool_result / format_tool_result_block
# ---------------------------------------------------------------------------

describe "CrystalLLM::Providers::Anthropic::Tools format_tool_result" do
  it "wraps a tool result message in role:user with a tool_result content block" do
    msg = tool_result_message("Tool result")
    result = CrystalLLM::Providers::Anthropic::Tools.format_tool_result(msg).as_h

    result["role"].as_s.should eq("user")
    outer = result["content"].as_a
    outer.size.should eq(1)

    block = outer[0].as_h
    block["type"].as_s.should eq("tool_result")
    block["tool_use_id"].as_s.should eq("tool_123")

    inner = block["content"].as_a
    inner.size.should eq(1)
    inner[0].as_h["type"].as_s.should eq("text")
    inner[0].as_h["text"].as_s.should eq("Tool result")
  end

  it "substitutes '(no output)' placeholder when content is empty string" do
    msg = tool_result_message("")
    result = CrystalLLM::Providers::Anthropic::Tools.format_tool_result(msg).as_h

    block = result["content"].as_a[0].as_h
    inner = block["content"].as_a
    inner[0].as_h["text"].as_s.should eq("(no output)")
  end

  it "substitutes '(no output)' placeholder when content is nil" do
    tc_msg = CrystalLLM::Message.new(
      role: CrystalLLM::Role::Tool,
      content: nil.as(String?),
      tool_call_id: "tool_nil"
    )
    result = CrystalLLM::Providers::Anthropic::Tools.format_tool_result(tc_msg).as_h

    block = result["content"].as_a[0].as_h
    inner = block["content"].as_a
    inner[0].as_h["text"].as_s.should eq("(no output)")
  end
end

# ---------------------------------------------------------------------------
# Tools: parse_tool_calls
# ---------------------------------------------------------------------------

describe "CrystalLLM::Providers::Anthropic::Tools parse_tool_calls" do
  it "parses multiple tool_use blocks from an array, skipping text blocks" do
    content_blocks = JSON.parse(<<-JSON)
    [
      {"type": "text", "text": "Rolling dice"},
      {"type": "tool_use", "id": "tool_1", "name": "dice_roll", "input": {}},
      {"type": "tool_use", "id": "tool_2", "name": "dice_roll", "input": {}},
      {"type": "tool_use", "id": "tool_3", "name": "dice_roll", "input": {}}
    ]
    JSON

    calls = CrystalLLM::Providers::Anthropic::Tools.parse_tool_calls(content_blocks)
    calls.should_not be_nil
    raise "no calls" unless calls
    calls.size.should eq(3)
    calls.keys.sort!.should eq(["tool_1", "tool_2", "tool_3"])
    calls.values.all?(&.name.==("dice_roll")).should be_true
  end

  it "handles a single tool_use block (not wrapped in an array)" do
    single_block = JSON.parse(<<-JSON)
    {"type": "tool_use", "id": "tool_1", "name": "dice_roll", "input": {}}
    JSON

    calls = CrystalLLM::Providers::Anthropic::Tools.parse_tool_calls(single_block)
    calls.should_not be_nil
    raise "no calls" unless calls
    calls.size.should eq(1)
    calls["tool_1"].name.should eq("dice_roll")
  end

  it "returns nil for nil input" do
    CrystalLLM::Providers::Anthropic::Tools.parse_tool_calls(nil).should be_nil
  end

  it "returns nil for an empty array" do
    empty = JSON::Any.new([] of JSON::Any)
    CrystalLLM::Providers::Anthropic::Tools.parse_tool_calls(empty).should be_nil
  end

  it "returns nil when all blocks are text (no tool_use blocks)" do
    text_only = JSON.parse(%([ {"type":"text","text":"hello"} ]))
    CrystalLLM::Providers::Anthropic::Tools.parse_tool_calls(text_only).should be_nil
  end

  it "preserves input arguments as a Hash" do
    block = JSON.parse(<<-JSON)
    {"type": "tool_use", "id": "t1", "name": "get_weather", "input": {"city": "Paris"}}
    JSON

    calls = CrystalLLM::Providers::Anthropic::Tools.parse_tool_calls(block)
    raise "no calls" unless calls
    calls["t1"].arguments["city"].as_s.should eq("Paris")
  end
end

# ---------------------------------------------------------------------------
# Media: format_content for PDF and unsupported attachments
# ---------------------------------------------------------------------------

describe "CrystalLLM::Providers::Anthropic::Media format_content (attachments)" do
  it "emits a document block with base64 source for a PDF attachment" do
    content = CrystalLLM::Content.new("Summarize this")
    content.attachments << pdf_attachment

    blocks = CrystalLLM::Providers::Anthropic::Media.format_content(content).as_a
    blocks.size.should eq(2)

    # First block is the text
    blocks[0].as_h["type"].as_s.should eq("text")
    blocks[0].as_h["text"].as_s.should eq("Summarize this")

    # Second block is the document
    doc_block = blocks[1].as_h
    doc_block["type"].as_s.should eq("document")
    source = doc_block["source"].as_h
    source["type"].as_s.should eq("base64")
    source["media_type"].as_s.should eq("application/pdf")
    source["data"].as_s.should eq(Base64.strict_encode(PDF_MAGIC_TOOLS))
  end

  it "emits only a document block (no text) when content has no text field" do
    # Content.new with only an attachment (no text). The Source alias includes IO,
    # so we pass the PDF IO directly; then add a properly-named pdf_attachment
    # so MimeType resolves to application/pdf via filename.
    io = IO::Memory.new
    io.write(PDF_MAGIC_TOOLS)
    io.rewind
    # Construct with the IO source (no filename — sniff needed); reset and re-add
    # with the named fixture so Content has only 1 attachment.
    content = CrystalLLM::Content.new(attachments: io.as(IO))
    content.attachments.clear
    content.attachments << pdf_attachment

    blocks = CrystalLLM::Providers::Anthropic::Media.format_content(content).as_a
    blocks.size.should eq(1)
    blocks[0].as_h["type"].as_s.should eq("document")
  end

  it "raises UnsupportedAttachmentError for a docx (unsupported document type)" do
    content = CrystalLLM::Content.new("Summarize this file")
    content.attachments << docx_attachment

    expect_raises(CrystalLLM::UnsupportedAttachmentError, /application\/vnd.openxmlformats/) do
      CrystalLLM::Providers::Anthropic::Media.format_content(content)
    end
  end
end

# ---------------------------------------------------------------------------
# Chat: build_system_content
# ---------------------------------------------------------------------------

describe "CrystalLLM::Providers::Anthropic build_system_content" do
  it "flattens a plain string system message into text blocks" do
    provider = configured_anthropic_tools
    msg = CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: "be terse")
    blocks = provider.build_system_content([msg])

    blocks.size.should eq(1)
    blocks[0].as_h["type"].as_s.should eq("text")
    blocks[0].as_h["text"].as_s.should eq("be terse")
  end

  it "flattens multiple system messages into a single flat block array" do
    provider = configured_anthropic_tools
    msgs = [
      CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: "rule one"),
      CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: "rule two"),
    ]
    blocks = provider.build_system_content(msgs)

    blocks.size.should eq(2)
    blocks[0].as_h["text"].as_s.should eq("rule one")
    blocks[1].as_h["text"].as_s.should eq("rule two")
  end

  it "passes Content::Raw system messages through unchanged (array flattening)" do
    provider = configured_anthropic_tools
    # Build a Raw value whose inner value is an array of blocks
    raw_block = JSON::Any.new({
      "type"          => JSON::Any.new("text"),
      "text"          => JSON::Any.new("raw instruction"),
      "cache_control" => JSON::Any.new({"type" => JSON::Any.new("ephemeral")} of String => JSON::Any),
    } of String => JSON::Any)
    raw_content = CrystalLLM::Content::Raw.new(JSON::Any.new([raw_block] of JSON::Any))
    msg = CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: raw_content)

    blocks = provider.build_system_content([msg])
    blocks.size.should eq(1)
    b = blocks[0].as_h
    b["type"].as_s.should eq("text")
    b["text"].as_s.should eq("raw instruction")
    b["cache_control"].as_h["type"].as_s.should eq("ephemeral")
  end

  it "mixes a Raw block and a plain string message into one flat sequence" do
    provider = configured_anthropic_tools
    raw_block = CrystalLLM::Providers::Anthropic::Content.build("cached rule", cache: true)
    raw_msg = CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: raw_block)
    plain_msg = CrystalLLM::Message.new(role: CrystalLLM::Role::System, content: "plain rule")

    blocks = provider.build_system_content([raw_msg, plain_msg])
    blocks.size.should eq(2)

    blocks[0].as_h["text"].as_s.should eq("cached rule")
    blocks[0].as_h["cache_control"].as_h["type"].as_s.should eq("ephemeral")
    blocks[1].as_h["text"].as_s.should eq("plain rule")
    blocks[1].as_h.has_key?("cache_control").should be_false
  end

  it "returns an empty array when there are no system messages" do
    provider = configured_anthropic_tools
    provider.build_system_content([] of CrystalLLM::Message).should be_empty
  end
end
