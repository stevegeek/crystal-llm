require "../spec_helper"
require "../../src/crystal_llm/providers/openai"
require "../../src/crystal_llm/providers/anthropic"
require "../../src/crystal_llm/providers/gemini"
require "../../src/crystal_llm/providers/bedrock"
require "../../src/crystal_llm/providers/vertexai"
require "../../src/crystal_llm/providers/deepseek"
require "../../src/crystal_llm/providers/xai"

# Covers the ATTACHMENT/MULTIMODAL media formatting for the big-3 providers —
# closing the "Content with attachments raises deferred" gap. No network: the
# attachment is constructed directly from PNG magic bytes in an IO::Memory.

# An 8-byte PNG signature; MimeType sniffs this as image/png regardless of name.
PNG_MAGIC = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
# A minimal PDF header; MimeType sniffs the leading "%PDF" as application/pdf.
PDF_MAGIC = "%PDF-1.4\n".to_slice

private def png_content : CrystalLLM::Content
  io = IO::Memory.new
  io.write(PNG_MAGIC)
  io.rewind
  attachment = CrystalLLM::Attachment.new(io, filename: "logo.png")
  content = CrystalLLM::Content.new("look at this")
  content.attachments << attachment
  content
end

private def pdf_content : CrystalLLM::Content
  io = IO::Memory.new
  io.write(PDF_MAGIC)
  io.rewind
  attachment = CrystalLLM::Attachment.new(io, filename: "report.pdf")
  content = CrystalLLM::Content.new("read this")
  content.attachments << attachment
  content
end

private def expected_b64 : String
  Base64.strict_encode(PNG_MAGIC)
end

private def expected_pdf_b64 : String
  Base64.strict_encode(PDF_MAGIC)
end

private def deepseek_provider : CrystalLLM::Providers::DeepSeek
  config = CrystalLLM::Configuration.new
  config.deepseek_api_key = "test"
  CrystalLLM::Providers::DeepSeek.new(config)
end

private def xai_provider : CrystalLLM::Providers::XAI
  config = CrystalLLM::Configuration.new
  config.xai_api_key = "test"
  CrystalLLM::Providers::XAI.new(config)
end

describe "attachment media formatting" do
  describe CrystalLLM::Providers::OpenAI::Media do
    it "sniffs the IO::Memory PNG as an image attachment" do
      png_content.attachments.first.image?.should be_true
      png_content.attachments.first.mime_type.should eq("image/png")
    end

    it "emits text + image_url parts for a Content with an image attachment" do
      result = CrystalLLM::Providers::OpenAI::Media.format_content(png_content)
      parts = result.as_a
      parts.size.should eq(2)

      parts[0].as_h["type"].as_s.should eq("text")
      parts[0].as_h["text"].as_s.should eq("look at this")

      image = parts[1].as_h
      image["type"].as_s.should eq("image_url")
      url = image["image_url"].as_h["url"].as_s
      url.should eq("data:image/png;base64,#{expected_b64}")
    end

    it "keeps bare text working (no regression)" do
      CrystalLLM::Providers::OpenAI::Media.format_content("hi").as_s.should eq("hi")
    end
  end

  describe CrystalLLM::Providers::Anthropic::Media do
    it "emits a base64 image source block" do
      result = CrystalLLM::Providers::Anthropic::Media.format_content(png_content)
      blocks = result.as_a
      blocks.size.should eq(2)

      blocks[0].as_h["type"].as_s.should eq("text")
      blocks[0].as_h["text"].as_s.should eq("look at this")

      image = blocks[1].as_h
      image["type"].as_s.should eq("image")
      source = image["source"].as_h
      source["type"].as_s.should eq("base64")
      source["media_type"].as_s.should eq("image/png")
      source["data"].as_s.should eq(expected_b64)
    end

    it "keeps bare text working (no regression)" do
      result = CrystalLLM::Providers::Anthropic::Media.format_content("hi")
      blocks = result.as_a
      blocks.size.should eq(1)
      blocks[0].as_h["type"].as_s.should eq("text")
      blocks[0].as_h["text"].as_s.should eq("hi")
    end
  end

  describe CrystalLLM::Providers::Gemini::Media do
    it "emits an inline_data image part" do
      parts = CrystalLLM::Providers::Gemini::Media.format_content(png_content)
      parts.size.should eq(2)

      parts[0].as_h["text"].as_s.should eq("look at this")

      inline = parts[1].as_h["inline_data"].as_h
      inline["mime_type"].as_s.should eq("image/png")
      inline["data"].as_s.should eq(expected_b64)
    end

    it "keeps bare text working (no regression)" do
      parts = CrystalLLM::Providers::Gemini::Media.format_content("hi")
      parts.size.should eq(1)
      parts[0].as_h["text"].as_s.should eq("hi")
    end
  end

  describe CrystalLLM::Providers::Bedrock::Media do
    it "emits an image content block for an image attachment" do
      used = {} of String => Int32
      attachment = png_content.attachments.first
      block = CrystalLLM::Providers::Bedrock::Media.render_attachment(attachment, used).as_h

      image = block["image"].as_h
      image["format"].as_s.should eq("png")
      image["source"].as_h["bytes"].as_s.should eq(expected_b64)
    end

    it "emits a document block for a pdf attachment, with a sanitized unique name" do
      used = {} of String => Int32
      attachment = pdf_content.attachments.first
      block = CrystalLLM::Providers::Bedrock::Media.render_attachment(attachment, used).as_h

      document = block["document"].as_h
      document["format"].as_s.should eq("pdf")
      document["name"].as_s.should eq("report")
      document["source"].as_h["bytes"].as_s.should eq(expected_pdf_b64)
    end

    it "de-duplicates repeated document names within a payload" do
      used = {} of String => Int32
      a1 = pdf_content.attachments.first
      a2 = pdf_content.attachments.first
      n1 = CrystalLLM::Providers::Bedrock::Media.render_attachment(a1, used).as_h["document"].as_h["name"].as_s
      n2 = CrystalLLM::Providers::Bedrock::Media.render_attachment(a2, used).as_h["document"].as_h["name"].as_s
      n1.should eq("report")
      n2.should eq("report_2")
    end

    it "renders text + image blocks through the Bedrock chat content path" do
      config = CrystalLLM::Configuration.new
      config.bedrock_api_key = "test"
      config.bedrock_secret_key = "test"
      config.bedrock_region = "us-east-1"
      provider = CrystalLLM::Providers::Bedrock.new(config)
      model = CrystalLLM::Model::Info.build(id: "anthropic.claude-3-sonnet", provider: "bedrock")
      message = CrystalLLM::Message.new(role: CrystalLLM::Role::User, content: png_content)

      payload = provider.render_payload(
        [message], {} of String => CrystalLLM::Tool, nil, model
      )
      blocks = payload["messages"].as_a.first.as_h["content"].as_a
      blocks.size.should eq(2)
      blocks[0].as_h["text"].as_s.should eq("look at this")
      blocks[1].as_h["image"].as_h["format"].as_s.should eq("png")
    end
  end

  describe CrystalLLM::Providers::VertexAI::Media do
    it "emits an inline_data image part (Gemini wire shape)" do
      parts = CrystalLLM::Providers::VertexAI::Media.format_content(png_content)
      parts.size.should eq(2)

      parts[0].as_h["text"].as_s.should eq("look at this")
      inline = parts[1].as_h["inline_data"].as_h
      inline["mime_type"].as_s.should eq("image/png")
      inline["data"].as_s.should eq(expected_b64)
    end

    it "no longer raises on a Content carrying an attachment" do
      parts = CrystalLLM::Providers::VertexAI::Media.format_content(pdf_content)
      parts[1].as_h["inline_data"].as_h["mime_type"].as_s.should eq("application/pdf")
    end

    it "keeps bare text working (no regression)" do
      parts = CrystalLLM::Providers::VertexAI::Media.format_content("hi")
      parts[0].as_h["text"].as_s.should eq("hi")
    end
  end

  describe CrystalLLM::Providers::DeepSeek do
    it "raises UnsupportedAttachmentError for an image attachment (text-only)" do
      expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        deepseek_provider.format_content(png_content)
      end
    end

    it "raises UnsupportedAttachmentError for a pdf attachment" do
      expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        deepseek_provider.format_content(pdf_content)
      end
    end

    it "passes plain text content through" do
      deepseek_provider.format_content("hello").as_s.should eq("hello")
    end
  end

  describe CrystalLLM::Providers::XAI do
    it "allows image attachments (image-only policy)" do
      result = xai_provider.format_content(png_content)
      parts = result.as_a
      parts[0].as_h["text"].as_s.should eq("look at this")
      parts[1].as_h["type"].as_s.should eq("image_url")
      parts[1].as_h["image_url"].as_h["url"].as_s.should eq("data:image/png;base64,#{expected_b64}")
    end

    it "raises UnsupportedAttachmentError for a pdf attachment (documents gated off)" do
      expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        xai_provider.format_content(pdf_content)
      end
    end

    it "passes plain text content through" do
      xai_provider.format_content("hello").as_s.should eq("hello")
    end
  end
end
