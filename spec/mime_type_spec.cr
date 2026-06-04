require "./spec_helper"

# Ports the behaviour of ruby_llm lib/ruby_llm/mime_type.rb (@ 1.15.0).
# `for` replaces marcel: stdlib MIME (by filename) + a magic-byte sniffer.
describe CrystalLLM::MimeType do
  it "recognises media families by prefix" do
    CrystalLLM::MimeType.image?("image/png").should be_true
    CrystalLLM::MimeType.image?("application/pdf").should be_false
    CrystalLLM::MimeType.video?("video/mp4").should be_true
    CrystalLLM::MimeType.audio?("audio/mpeg").should be_true
    CrystalLLM::MimeType.pdf?("application/pdf").should be_true
    CrystalLLM::MimeType.pdf?("image/png").should be_false
  end

  describe ".text?" do
    it "matches text/* and structured-suffix and listed application types" do
      CrystalLLM::MimeType.text?("text/plain").should be_true
      CrystalLLM::MimeType.text?("application/ld+json").should be_true
      CrystalLLM::MimeType.text?("application/json").should be_true
      CrystalLLM::MimeType.text?("application/yaml").should be_true
      CrystalLLM::MimeType.text?("image/png").should be_false
    end
  end

  describe ".document?" do
    it "matches office/opendocument types but never pdf or text" do
      CrystalLLM::MimeType.document?("application/msword").should be_true
      CrystalLLM::MimeType.document?(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ).should be_true
      CrystalLLM::MimeType.document?("application/pdf").should be_false
      CrystalLLM::MimeType.document?("text/plain").should be_false
    end
  end

  describe ".for" do
    it "sniffs common formats by magic bytes" do
      png = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]
      CrystalLLM::MimeType.for(png).should eq("image/png")

      jpeg = Bytes[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
      CrystalLLM::MimeType.for(jpeg).should eq("image/jpeg")

      pdf = "%PDF-1.7\n".to_slice
      CrystalLLM::MimeType.for(pdf).should eq("application/pdf")
    end

    it "falls back to the filename extension" do
      CrystalLLM::MimeType.for(name: "report.png").should eq("image/png")
    end

    it "uses the declared type, then octet-stream, as last resorts" do
      CrystalLLM::MimeType.for(declared_type: "audio/ogg").should eq("audio/ogg")
      CrystalLLM::MimeType.for(Bytes[0x00, 0x01, 0x02]).should eq("application/octet-stream")
    end

    it "honours precedence: magic bytes beat filename beat declared type" do
      png = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
      CrystalLLM::MimeType.for(png, name: "notes.txt", declared_type: "text/plain").should eq("image/png")
      CrystalLLM::MimeType.for(name: "logo.png", declared_type: "text/plain").should eq("image/png")
    end

    it "sniffs GIF and WEBP headers" do
      CrystalLLM::MimeType.for("GIF89a".to_slice).should eq("image/gif")
      webp = Bytes[0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]
      CrystalLLM::MimeType.for(webp).should eq("image/webp")
    end
  end
end
