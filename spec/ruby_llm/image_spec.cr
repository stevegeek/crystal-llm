require "../spec_helper"
require "../../src/crystal_llm/image"
require "http/server"

# Unit-level port of lib/ruby_llm/image.rb (@ 1.15.0). The upstream spec is
# VCR/integration (live image generation); this exercises the pure data class.
describe CrystalLLM::Image do
  describe "#base64?" do
    it "is true when data is present" do
      image = CrystalLLM::Image.new(data: Base64.encode("hi"), mime_type: "image/png")
      image.base64?.should be_true
    end

    it "is false for a url-backed image" do
      image = CrystalLLM::Image.new(url: "https://example.com/a.png")
      image.base64?.should be_false
    end
  end

  describe "#to_blob" do
    it "decodes base64 data" do
      image = CrystalLLM::Image.new(data: Base64.encode("PNGBYTES"))
      String.new(image.to_blob).should eq("PNGBYTES")
    end

    # Parity quick win: a url-backed image fetches its bytes via
    # `Connection.basic_get` (ruby_llm's `Connection.basic.get(url).body`) rather
    # than raising. Served from a local in-process HTTP server (no external net).
    it "fetches bytes for a url-backed image via Connection.basic_get" do
      server = HTTP::Server.new do |context|
        context.response.content_type = "image/png"
        context.response.print("REMOTEBYTES")
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      begin
        url = "http://#{address.address}:#{address.port}/a.png"
        image = CrystalLLM::Image.new(url: url)
        String.new(image.to_blob).should eq("REMOTEBYTES")
      ensure
        server.close
      end
    end

    it "raises when an image has neither data nor url" do
      image = CrystalLLM::Image.new
      expect_raises(ArgumentError) { image.to_blob }
    end
  end

  describe "#save" do
    it "writes the decoded bytes and returns the path" do
      path = File.tempname("crystal_llm_image", ".png")
      begin
        image = CrystalLLM::Image.new(data: Base64.encode("PNGBYTES"))
        image.save(path).should eq(path)
        File.read(path).should eq("PNGBYTES")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  describe "accessors" do
    it "exposes url, mime_type, revised_prompt and model_id" do
      image = CrystalLLM::Image.new(
        url: "https://example.com/a.png",
        mime_type: "image/png",
        revised_prompt: "a green logo",
        model_id: "gpt-image-1",
      )
      image.url.should eq("https://example.com/a.png")
      image.mime_type.should eq("image/png")
      image.revised_prompt.should eq("a green logo")
      image.model_id.should eq("gpt-image-1")
    end

    it "defaults usage to an empty hash" do
      CrystalLLM::Image.new(url: "https://example.com/a.png").usage.should be_empty
    end
  end

  describe "#tokens" do
    it "builds Tokens from usage values" do
      usage = {
        "input_tokens"  => JSON::Any.new(11_i64),
        "output_tokens" => JSON::Any.new(22_i64),
      }
      tokens = CrystalLLM::Image.new(model_id: "gpt-image-1", usage: usage).tokens
      tokens.should be_a(CrystalLLM::Tokens)
      raise "expected tokens" unless tokens
      tokens.input.should eq(11)
      tokens.output.should eq(22)
    end

    it "is nil when usage carries no token counts" do
      CrystalLLM::Image.new(url: "https://example.com/a.png").tokens.should be_nil
    end
  end
end
