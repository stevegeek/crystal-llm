require "../spec_helper"
require "../../src/crystal_llm/providers/perplexity"

# Covers Perplexity attachment media formatting (ported from perplexity/media.rb).
# Perplexity supports images (via OpenAI::Media) and document attachments
# (pdf/doc/docx/txt/rtf) as `{type:"file_url", file_url:{url}}` parts.

private def perplexity_png_content : CrystalLLM::Content
  io = IO::Memory.new
  io.write(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  io.rewind
  content = CrystalLLM::Content.new("look at this")
  content.attachments << CrystalLLM::Attachment.new(io, filename: "photo.png")
  content
end

private def perplexity_pdf_content : CrystalLLM::Content
  io = IO::Memory.new("%PDF-1.4\n".to_slice)
  io.rewind
  content = CrystalLLM::Content.new("read this")
  content.attachments << CrystalLLM::Attachment.new(io, filename: "report.pdf")
  content
end

private def configured_perplexity_media : CrystalLLM::Providers::Perplexity
  config = CrystalLLM::Configuration.new
  config.perplexity_api_key = "test"
  CrystalLLM::Providers::Perplexity.new(config)
end

describe "CrystalLLM::Providers::Perplexity::Media" do
  describe "#format_content" do
    it "passes plain text through as a bare string" do
      CrystalLLM::Providers::Perplexity::Media.format_content("hello").as_s.should eq("hello")
    end

    it "emits text + image_url parts for an image attachment" do
      result = CrystalLLM::Providers::Perplexity::Media.format_content(perplexity_png_content)
      parts = result.as_a
      parts.size.should eq(2)

      parts[0].as_h["type"].as_s.should eq("text")
      parts[0].as_h["text"].as_s.should eq("look at this")

      img = parts[1].as_h
      img["type"].as_s.should eq("image_url")
      img["image_url"].as_h["url"].as_s.should start_with("data:image/png;base64,")
    end

    it "emits a file_url part for a pdf attachment" do
      result = CrystalLLM::Providers::Perplexity::Media.format_content(perplexity_pdf_content)
      parts = result.as_a
      parts.size.should eq(2)

      parts[0].as_h["type"].as_s.should eq("text")
      doc = parts[1].as_h
      doc["type"].as_s.should eq("file_url")
      doc["file_url"].as_h["url"].as_s.should_not be_empty
    end

    it "supported_file? returns true for pdf" do
      io = IO::Memory.new("%PDF-1.4\n".to_slice)
      io.rewind
      attachment = CrystalLLM::Attachment.new(io, filename: "doc.pdf")
      CrystalLLM::Providers::Perplexity::Media.supported_file?(attachment).should be_true
    end

    it "supported_file? returns true for .docx extension" do
      io = IO::Memory.new("PK\x03\x04docx".to_slice)
      io.rewind
      attachment = CrystalLLM::Attachment.new(io, filename: "report.docx")
      CrystalLLM::Providers::Perplexity::Media.supported_file?(attachment).should be_true
    end

    it "raises UnsupportedAttachmentError for an unsupported document type" do
      io = IO::Memory.new("some xlsx bytes".to_slice)
      io.rewind
      content = CrystalLLM::Content.new("data")
      content.attachments << CrystalLLM::Attachment.new(io, filename: "data.xlsx")
      expect_raises(CrystalLLM::UnsupportedAttachmentError) do
        CrystalLLM::Providers::Perplexity::Media.format_content(content)
      end
    end

    it "format_content is called by the provider instance" do
      provider = configured_perplexity_media
      result = provider.format_content(perplexity_pdf_content)
      parts = result.as_a
      doc = parts[1].as_h
      doc["type"].as_s.should eq("file_url")
    end

    # Direct mirror of upstream's rewritten open_ai/chat_spec.rb "keeps Perplexity
    # text file attachments as text parts" example, added in ruby_llm 1.16.0 /
    # 329cfe4f "Keep text attachments as text". Text-typed attachments (txt is also
    # in SUPPORTED_DOCUMENT_EXTENSIONS) used to be promoted to a file_url part via
    # format_document; format_text_attachment now always uses OpenAI::Media.
    # format_text_file instead, for every text extension (not just txt).
    it "keeps text file attachments as text parts (not promoted to file_url)" do
      %w[csv txt md html json].each do |extension|
        io = IO::Memory.new("notes".to_slice)
        io.rewind
        attachment = CrystalLLM::Attachment.new(io, filename: "notes.#{extension}")
        attachment.type.should eq(:text)

        part = CrystalLLM::Providers::Perplexity::Media.format_text_attachment(attachment).as_h
        part["type"].as_s.should eq("text")
        part["text"].as_s.should eq(attachment.for_llm)
      end
    end
  end
end
