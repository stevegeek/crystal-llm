require "../spec_helper"
require "../../src/crystal_llm/providers/azure"

# Covers Azure attachment media formatting (ported from azure/media.rb).
# Azure images use {type:"image_url", image_url:{url}} (no detail key).
# Audio reuses OpenAI::Media.format_audio; documents/pdf are unsupported.

private def azure_png_content : CrystalLLM::Content
  io = IO::Memory.new
  io.write(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) # PNG magic
  io.rewind
  content = CrystalLLM::Content.new("look at this")
  content.attachments << CrystalLLM::Attachment.new(io, filename: "logo.png")
  content
end

private def configured_azure_media : CrystalLLM::Providers::Azure
  config = CrystalLLM::Configuration.new
  config.azure_api_base = "https://my-resource.openai.azure.com/openai/deployments/gpt-4"
  config.azure_api_key = "test"
  CrystalLLM::Providers::Azure.new(config)
end

describe "CrystalLLM::Providers::Azure::Media" do
  describe "#format_content" do
    it "emits text + image_url parts (no detail key)" do
      result = CrystalLLM::Providers::Azure::Media.format_content(azure_png_content)
      parts = result.as_a
      parts.size.should eq(2)

      parts[0].as_h["type"].as_s.should eq("text")
      parts[0].as_h["text"].as_s.should eq("look at this")

      img = parts[1].as_h
      img["type"].as_s.should eq("image_url")
      image_url = img["image_url"].as_h
      image_url["url"].as_s.should start_with("data:image/png;base64,")
      image_url.has_key?("detail").should be_false
    end

    it "passes plain text through as a bare string" do
      CrystalLLM::Providers::Azure::Media.format_content("hello").as_s.should eq("hello")
    end

    it "passes Content::Raw through unchanged" do
      raw = CrystalLLM::Content::Raw.new(JSON::Any.new("passthrough"))
      CrystalLLM::Providers::Azure::Media.format_content(raw).as_s.should eq("passthrough")
    end

    it "raises UnsupportedAttachmentError for a pdf (unsupported)" do
      io = IO::Memory.new("%PDF-1.4\n".to_slice)
      io.rewind
      content = CrystalLLM::Content.new("read")
      content.attachments << CrystalLLM::Attachment.new(io, filename: "report.pdf")
      expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        CrystalLLM::Providers::Azure::Media.format_content(content)
      end
    end

    it "format_content is called by the provider instance" do
      provider = configured_azure_media
      result = provider.format_content(azure_png_content)
      parts = result.as_a
      img = parts[1].as_h
      img["type"].as_s.should eq("image_url")
      img["image_url"].as_h.has_key?("detail").should be_false
    end
  end
end
