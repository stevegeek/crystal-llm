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

  describe "#model_info" do
    it "resolves the registry Model::Info for the image's model_id" do
      info = CrystalLLM::Image.new(model_id: "gpt-image-1").model_info
      info.should be_a(CrystalLLM::Model::Info)
      raise "expected model_info" unless info
      info.id.should eq("gpt-image-1")
    end

    it "is nil when there is no model id" do
      CrystalLLM::Image.new(url: "https://example.com/a.png").model_info.should be_nil
    end

    it "is nil when the model id is not in the registry" do
      CrystalLLM::Image.new(model_id: "totally-made-up-model-xyz").model_info.should be_nil
    end
  end

  describe "#cost" do
    # gpt-image-1 (openai) registry pricing: text input 5.0/M, image input
    # 10.0/M, image output 40.0/M. With 100 text-input + 250 image-input tokens
    # and 50 output tokens (mirrors cost_spec's image-cost case):
    #   input  = 100*5/1M + 250*10/1M = 0.0005 + 0.0025 = 0.003
    #   output = 50*40/1M                                = 0.002
    #   total                                            = 0.005
    it "prices the paint request in the images category using input token details" do
      usage = {
        "input_tokens"         => JSON::Any.new(350_i64),
        "output_tokens"        => JSON::Any.new(50_i64),
        "input_tokens_details" => JSON::Any.new({
          "text_tokens"  => JSON::Any.new(100_i64),
          "image_tokens" => JSON::Any.new(250_i64),
        }),
      }
      cost = CrystalLLM::Image.new(model_id: "gpt-image-1", usage: usage).cost

      cost.category.images?.should be_true
      cost.input.try(&.should be_close(0.003, 0.0000000001))
      cost.output.try(&.should be_close(0.002, 0.0000000001))
      cost.total.try(&.should be_close(0.005, 0.0000000001))
    end

    it "has no token costs and an unknown model when usage and model_id are absent" do
      cost = CrystalLLM::Image.new(url: "https://example.com/a.png").cost

      cost.tokens?.should be_false
      cost.model.should be_nil
      cost.total.should be_nil
    end
  end
end
