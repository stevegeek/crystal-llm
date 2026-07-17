require "./spec_helper"

# Ports ruby_llm spec/ruby_llm/content_spec.rb (@ 1.16.0, commit a6a02653) plus the
# Content#build_attachment passthrough behavior (commit 9a08dd1c, same diff range
# 6e634fd..1.16.0 -- lib/ruby_llm/content.rb).
describe CrystalLLM::Content do
  describe "#empty?" do
    it "is true when text is empty and there are no attachments" do
      CrystalLLM::Content.new("").empty?.should be_true
    end

    it "is false when text is present" do
      CrystalLLM::Content.new("hello").empty?.should be_false
    end

    it "is false when attachments are present without text" do
      CrystalLLM::Content.new(attachments: "spec/fixtures/ruby.txt").empty?.should be_false
    end

    it "is false when empty text has attachments" do
      CrystalLLM::Content.new("", "spec/fixtures/ruby.txt").empty?.should be_false
    end
  end

  describe "#add_attachment" do
    it "reuses an existing Attachment instance unchanged (identity preserved)" do
      attachment = CrystalLLM::Attachment.new(IO::Memory.new("Test content"), filename: "test.txt")
      content = CrystalLLM::Content.new("Check this")

      content.add_attachment(attachment)

      content.attachments.last.should be(attachment)
    end

    it "re-wraps an existing Attachment when a new filename is given" do
      attachment = CrystalLLM::Attachment.new(IO::Memory.new("Test content"), filename: "test.txt")
      content = CrystalLLM::Content.new("Check this")

      content.add_attachment(attachment, filename: "renamed.txt")

      reused = content.attachments.last
      reused.should_not be(attachment)
      reused.source.should eq(attachment.source)
      reused.filename.should eq("renamed.txt")
    end

    it "still wraps a plain source (String) into a new Attachment" do
      content = CrystalLLM::Content.new("Check this")

      content.add_attachment("spec/fixtures/ruby.txt")

      content.attachments.last.filename.should eq("ruby.txt")
    end
  end
end
