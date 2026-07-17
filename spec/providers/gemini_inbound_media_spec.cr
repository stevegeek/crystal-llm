require "../spec_helper"
require "../../src/crystal_llm/providers/gemini"

# Covers Gemini inbound attachment rebuild (ported from gemini/media.rb's
# build_response_content / build_inline_attachment / build_file_attachment /
# attachment_filename). These methods parse Gemini response `parts` arrays back
# into CrystalLLM::Content objects when binary attachments are present.

private def configured_gemini_inbound : CrystalLLM::Providers::Gemini
  config = CrystalLLM::Configuration.new
  config.gemini_api_key = "test"
  CrystalLLM::Providers::Gemini.new(config)
end

private def png_b64 : String
  Base64.strict_encode(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
end

describe "CrystalLLM::Providers::Gemini inbound media" do
  describe "#attachment_filename" do
    it "falls back to index name when mime_type is nil" do
      g = configured_gemini_inbound
      g.attachment_filename(nil, 0).should eq("gemini_attachment_1")
      g.attachment_filename(nil, 2).should eq("gemini_attachment_3")
    end

    it "maps jpeg -> jpg" do
      configured_gemini_inbound.attachment_filename("image/jpeg", 0).should eq("gemini_attachment_1.jpg")
    end

    it "maps text/plain -> .txt" do
      configured_gemini_inbound.attachment_filename("text/plain", 1).should eq("gemini_attachment_2.txt")
    end

    it "converts + to . in sub-types (e.g. svg+xml)" do
      configured_gemini_inbound.attachment_filename("image/svg+xml", 0).should eq("gemini_attachment_1.svg.xml")
    end

    it "uses the raw sub-type for simple cases" do
      g = configured_gemini_inbound
      g.attachment_filename("image/png", 0).should eq("gemini_attachment_1.png")
      g.attachment_filename("audio/mp4", 3).should eq("gemini_attachment_4.mp4")
    end
  end

  describe "#build_inline_attachment" do
    it "decodes base64 inline data into an Attachment" do
      inline = {
        "data"     => JSON::Any.new(png_b64),
        "mimeType" => JSON::Any.new("image/png"),
      } of String => JSON::Any
      att = configured_gemini_inbound.build_inline_attachment(inline, 0)
      att.should_not be_nil
      att = att.as(CrystalLLM::Attachment)
      att.filename.should eq("gemini_attachment_1.png")
      att.image?.should be_true
    end

    it "returns nil when data key is absent" do
      inline = {"mimeType" => JSON::Any.new("image/png")} of String => JSON::Any
      configured_gemini_inbound.build_inline_attachment(inline, 0).should be_nil
    end

    it "returns nil (and logs) on invalid base64" do
      inline = {
        "data"     => JSON::Any.new("not-valid-base64!!!"),
        "mimeType" => JSON::Any.new("image/png"),
      } of String => JSON::Any
      # Should not raise — returns nil and logs a warning
      result = configured_gemini_inbound.build_inline_attachment(inline, 0)
      result.should be_nil
    end
  end

  describe "#build_file_attachment" do
    it "builds an Attachment from a fileUri" do
      file = {
        "fileUri"  => JSON::Any.new("https://example.com/files/abc123"),
        "mimeType" => JSON::Any.new("image/jpeg"),
      } of String => JSON::Any
      att = configured_gemini_inbound.build_file_attachment(file, 0)
      att.should_not be_nil
      att = att.as(CrystalLLM::Attachment)
      att.source.should eq("https://example.com/files/abc123")
      att.filename.should eq("gemini_attachment_1.jpg")
    end

    it "uses the filename field when present" do
      file = {
        "fileUri"  => JSON::Any.new("https://example.com/files/abc"),
        "filename" => JSON::Any.new("document.pdf"),
      } of String => JSON::Any
      att = configured_gemini_inbound.build_file_attachment(file, 0)
      att.should_not be_nil
      att.as(CrystalLLM::Attachment).filename.should eq("document.pdf")
    end

    it "returns nil when fileUri is absent" do
      file = {"mimeType" => JSON::Any.new("image/png")} of String => JSON::Any
      configured_gemini_inbound.build_file_attachment(file, 0).should be_nil
    end
  end

  describe "#build_response_content" do
    it "returns joined text when parts are text-only" do
      parts = [
        JSON::Any.new({"text" => JSON::Any.new("Hello ")} of String => JSON::Any),
        JSON::Any.new({"text" => JSON::Any.new("world")} of String => JSON::Any),
      ]
      result = configured_gemini_inbound.build_response_content(parts)
      result.should eq("Hello world")
    end

    it "returns nil when parts is empty" do
      configured_gemini_inbound.build_response_content([] of JSON::Any).should be_nil
    end

    it "returns a Content with an inline attachment when inlineData is present" do
      parts = [
        JSON::Any.new({"text" => JSON::Any.new("Here is an image:")} of String => JSON::Any),
        JSON::Any.new({
          "inlineData" => JSON::Any.new({
            "data"     => JSON::Any.new(png_b64),
            "mimeType" => JSON::Any.new("image/png"),
          } of String => JSON::Any),
        } of String => JSON::Any),
      ]
      result = configured_gemini_inbound.build_response_content(parts)
      result.should be_a(CrystalLLM::Content)
      content = result.as(CrystalLLM::Content)
      content.text.should eq("Here is an image:")
      content.attachments.size.should eq(1)
      content.attachments.first.image?.should be_true
    end

    it "returns a Content with a file attachment when fileData is present" do
      parts = [
        JSON::Any.new({
          "fileData" => JSON::Any.new({
            "fileUri"  => JSON::Any.new("https://example.com/file.jpg"),
            "mimeType" => JSON::Any.new("image/jpeg"),
          } of String => JSON::Any),
        } of String => JSON::Any),
      ]
      result = configured_gemini_inbound.build_response_content(parts)
      result.should be_a(CrystalLLM::Content)
      content = result.as(CrystalLLM::Content)
      content.attachments.size.should eq(1)
      content.attachments.first.source.should eq("https://example.com/file.jpg")
    end

    it "returns text-only String when inline data is missing (nil attachment)" do
      # A part with inlineData but no 'data' key → nil attachment → text-only path
      parts = [
        JSON::Any.new({"text" => JSON::Any.new("only text")} of String => JSON::Any),
        JSON::Any.new({
          "inlineData" => JSON::Any.new({
            "mimeType" => JSON::Any.new("image/png"),
          } of String => JSON::Any),
        } of String => JSON::Any),
      ]
      result = configured_gemini_inbound.build_response_content(parts)
      result.should eq("only text")
    end

    # Direct mirror of upstream's new gemini/media_spec.rb "#build_response_content
    # parses inline image responses as content attachments" example, added in
    # ruby_llm 1.16.0 / 9a08dd1c. That commit's actual Ruby bug was that
    # `Gemini::Media#build_response_content` called `Content.new(text:, attachments:)`
    # with KEYWORD args against a positional-only `initialize(text = nil,
    # attachments = nil)` — Ruby silently folded both into a single Hash passed as
    # the `text` positional param, so `@attachments` stayed empty and inline image
    # bytes were dropped. This port's `build_response_content` never had that bug:
    # it builds `Content.new(text, built_attachments)` via the `Array(Attachment)`
    # positional overload (content.cr), which assigns the already-decoded
    # `Attachment` objects directly (bypassing `add_attachment`/`process_attachments`
    # entirely — see the divergence note above `build_response_content`). This spec
    # verifies that already-correct persistence path rather than re-porting a fix
    # that doesn't apply here.
    it "parses a pure inline-image response (no text) as a Content with a named attachment" do
      image_bytes = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
      parts = [
        JSON::Any.new({
          "inlineData" => JSON::Any.new({
            "mimeType" => JSON::Any.new("image/png"),
            "data"     => JSON::Any.new(Base64.strict_encode(image_bytes)),
          } of String => JSON::Any),
        } of String => JSON::Any),
      ]

      result = configured_gemini_inbound.build_response_content(parts)
      result.should be_a(CrystalLLM::Content)
      content = result.as(CrystalLLM::Content)
      content.text.should be_nil
      content.attachments.size.should eq(1)

      attachment = content.attachments.first
      attachment.filename.should eq("gemini_attachment_1.png")
      attachment.mime_type.should eq("image/png")
      attachment.content.should eq(image_bytes)

      message = CrystalLLM::Message.new(role: CrystalLLM::Role::Assistant, content: content)
      message.content.should be_a(CrystalLLM::Content)
    end
  end

  describe "parse_completion_response uses build_response_content" do
    # NOTE: ruby_llm's `parse_completion_response` uses `extract_text_parts(parts)
    # || parse_content(data)` — `extract_text_parts` wins when text parts exist.
    # `build_response_content` is called ONLY when there are no text parts (e.g.,
    # pure-image responses). The tests below reflect that faithful behavior.

    it "rebuilds a Content with an image attachment when the response has inlineData only (no text parts)" do
      body = {
        "modelVersion" => JSON::Any.new("gemini-2.5-flash"),
        "candidates"   => JSON::Any.new([
          JSON::Any.new({
            "content" => JSON::Any.new({
              "parts" => JSON::Any.new([
                JSON::Any.new({
                  "inlineData" => JSON::Any.new({
                    "data"     => JSON::Any.new(png_b64),
                    "mimeType" => JSON::Any.new("image/png"),
                  } of String => JSON::Any),
                } of String => JSON::Any),
              ]),
            } of String => JSON::Any),
          } of String => JSON::Any),
        ]),
        "usageMetadata" => JSON::Any.new({
          "promptTokenCount"     => JSON::Any.new(10),
          "candidatesTokenCount" => JSON::Any.new(5),
        } of String => JSON::Any),
      }.to_json

      provider = configured_gemini_inbound
      response = Crest::Response.new(
        HTTP::Client::Response.new(200, body: body),
        Crest::Request.new(:post, "http://example.test")
      )
      message = provider.parse_completion_response(response)

      message.role.should eq(CrystalLLM::Role::Assistant)
      content = message.content
      content.should be_a(CrystalLLM::Content)
      c = content.as(CrystalLLM::Content)
      c.attachments.size.should eq(1)
      c.attachments.first.image?.should be_true
    end

    it "returns text as a String when there are both text and inlineData parts (text wins)" do
      body = {
        "modelVersion" => JSON::Any.new("gemini-2.5-flash"),
        "candidates"   => JSON::Any.new([
          JSON::Any.new({
            "content" => JSON::Any.new({
              "parts" => JSON::Any.new([
                JSON::Any.new({"text" => JSON::Any.new("Here is the image:")} of String => JSON::Any),
                JSON::Any.new({
                  "inlineData" => JSON::Any.new({
                    "data"     => JSON::Any.new(png_b64),
                    "mimeType" => JSON::Any.new("image/png"),
                  } of String => JSON::Any),
                } of String => JSON::Any),
              ]),
            } of String => JSON::Any),
          } of String => JSON::Any),
        ]),
        "usageMetadata" => JSON::Any.new({} of String => JSON::Any),
      }.to_json

      provider = configured_gemini_inbound
      response = Crest::Response.new(
        HTTP::Client::Response.new(200, body: body),
        Crest::Request.new(:post, "http://example.test")
      )
      message = provider.parse_completion_response(response)
      # extract_text_parts returns "Here is the image:" (non-nil), so build_response_content
      # is not called — faithful to ruby_llm's || short-circuit behavior.
      message.content.should eq("Here is the image:")
    end
  end
end
