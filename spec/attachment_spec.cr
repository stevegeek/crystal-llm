require "./spec_helper"

# Ports ruby_llm spec/ruby_llm/attachment_spec.rb (@ 1.15.0).
# StringIO → IO::Memory; the path test goes through Content like the gem's does.
describe CrystalLLM::Attachment do
  it "supports path attachments from the public API" do
    content = CrystalLLM::Content.new("What is in this file?", "spec/fixtures/ruby.txt")
    attachment = content.attachments.first
    attachment.filename.should eq("ruby.txt")
    attachment.mime_type.should eq("text/plain")
    attachment.path?.should be_true
  end

  it "classifies rich document files semantically" do
    attachment = CrystalLLM::Attachment.new(IO::Memory.new("docx bytes"), filename: "proposal.docx")

    attachment.mime_type.should eq(
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    attachment.type.should eq(:document)
    attachment.document?.should be_true
    attachment.extension.should eq("docx")
  end

  it "keeps text files in one attachment category" do
    attachment = CrystalLLM::Attachment.new(IO::Memory.new("notes"), filename: "notes.txt")

    attachment.type.should eq(:text)
    attachment.text?.should be_true
    attachment.document?.should be_false
  end

  it "reads and base64-encodes IO content" do
    attachment = CrystalLLM::Attachment.new(IO::Memory.new("hello"), filename: "greeting.txt")
    String.new(attachment.content || Bytes.empty).should eq("hello")
    attachment.encoded.should eq(Base64.strict_encode("hello"))
  end
end

describe CrystalLLM::Content do
  it "returns the bare text when there are no attachments" do
    CrystalLLM::Content.new("just text").format.should eq("just text")
  end

  it "keeps itself as the format when attachments are present" do
    content = CrystalLLM::Content.new("look", "spec/fixtures/ruby.txt")
    content.format.should be(content)
    content.attachments.size.should eq(1)
  end

  it "raises when given neither text nor attachments" do
    expect_raises(ArgumentError, "cannot be both nil") do
      CrystalLLM::Content.new
    end
  end

  it "skips blank string attachments" do
    content = CrystalLLM::Content.new("hi", ["spec/fixtures/ruby.txt", "  "] of CrystalLLM::Source)
    content.attachments.size.should eq(1)
  end
end
