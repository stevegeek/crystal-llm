require "../spec_helper"
require "../../src/crystal_llm/providers/openai"
require "../../src/crystal_llm/providers/anthropic"
require "../../src/crystal_llm/providers/gemini"

# Covers the ATTACHMENT/MULTIMODAL media formatting for the big-3 providers —
# closing the "Content with attachments raises deferred" gap. No network: the
# attachment is constructed directly from PNG magic bytes in an IO::Memory.

# An 8-byte PNG signature; MimeType sniffs this as image/png regardless of name.
PNG_MAGIC = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

private def png_content : CrystalLLM::Content
  io = IO::Memory.new
  io.write(PNG_MAGIC)
  io.rewind
  attachment = CrystalLLM::Attachment.new(io, filename: "logo.png")
  content = CrystalLLM::Content.new("look at this")
  content.attachments << attachment
  content
end

private def expected_b64 : String
  Base64.strict_encode(PNG_MAGIC)
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
end
