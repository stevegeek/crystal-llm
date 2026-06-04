require "../spec_helper"
require "../../src/crystal_llm/provider_media"
require "../../src/crystal_llm/providers/openrouter"
require "../../src/crystal_llm/providers/openrouter/images"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:post, "http://example.test")
  )
end

private def configured_openrouter : CrystalLLM::Providers::OpenRouter
  config = CrystalLLM::Configuration.new
  config.openrouter_api_key = "test"
  CrystalLLM::Providers::OpenRouter.new(config)
end

describe "CrystalLLM::Providers::OpenRouter media (images)" do
  describe "#images_url" do
    it "routes image generation through the chat completions endpoint" do
      provider = configured_openrouter
      provider.images_url(with: nil, mask: nil).should eq("chat/completions")
      # with:/mask: are ignored — still the chat endpoint (no edit path)
      provider.images_url(with: "img.png", mask: nil).should eq("chat/completions")
    end
  end

  describe "#render_image_payload" do
    it "renders a chat-completions payload with image+text modalities" do
      payload = configured_openrouter.render_image_payload(
        "a cat", model: "google/gemini-2.5-flash-image-preview", size: "1024x1024",
        with: nil, mask: nil, params: {} of String => JSON::Any
      )

      payload["model"].as_s.should eq("google/gemini-2.5-flash-image-preview")
      payload["modalities"].as_a.map(&.as_s).should eq(["image", "text"])

      msgs = payload["messages"].as_a
      msgs.size.should eq(1)
      msgs[0].as_h["role"].as_s.should eq("user")
      msgs[0].as_h["content"].as_s.should eq("a cat")
    end

    it "ignores size and params (OpenRouter divergence)" do
      params = {"quality" => JSON::Any.new("hd")} of String => JSON::Any
      payload = configured_openrouter.render_image_payload(
        "a dog", model: "m", size: "256x256",
        with: nil, mask: nil, params: params
      )
      payload.has_key?("size").should be_false
      payload.has_key?("quality").should be_false
    end
  end

  describe "#parse_image_response" do
    it "builds a base64 Image from a data: URL in the images array" do
      body = <<-JSON
      {
        "choices": [
          {"message": {"role": "assistant", "content": "",
            "images": [
              {"type": "image_url",
               "image_url": {"url": "data:image/png;base64,aGVsbG8="}}
            ]}}
        ]
      }
      JSON
      image = configured_openrouter.parse_image_response(
        build_response(200, body), model: "google/gemini-2.5-flash-image-preview"
      )
      image.base64?.should be_true
      image.data.should eq("aGVsbG8=")
      image.mime_type.should eq("image/png")
      image.model_id.should eq("google/gemini-2.5-flash-image-preview")
      image.url.should be_nil
    end

    it "builds a url-backed Image from a regular image_url" do
      body = <<-JSON
      {
        "choices": [
          {"message": {"role": "assistant",
            "images": [{"image_url": {"url": "https://x/y.png"}}]}}
        ]
      }
      JSON
      image = configured_openrouter.parse_image_response(build_response(200, body), model: "m")
      image.base64?.should be_false
      image.url.should eq("https://x/y.png")
      image.mime_type.should eq("image/png")
    end

    it "falls back to a top-level url key on the image entry" do
      body = <<-JSON
      {
        "choices": [
          {"message": {"images": [{"url": "https://z/w.png"}]}}
        ]
      }
      JSON
      image = configured_openrouter.parse_image_response(build_response(200, body), model: "m")
      image.url.should eq("https://z/w.png")
    end

    it "raises when the message has no images" do
      body = <<-JSON
      {"choices": [{"message": {"role": "assistant", "content": "no image"}}]}
      JSON
      expect_raises(CrystalLLM::Error, /Unexpected response format/) do
        configured_openrouter.parse_image_response(build_response(200, body), model: "m")
      end
    end

    it "raises when the images array is empty" do
      body = %({"choices": [{"message": {"images": []}}]})
      expect_raises(CrystalLLM::Error, /Unexpected response format/) do
        configured_openrouter.parse_image_response(build_response(200, body), model: "m")
      end
    end

    it "raises on a malformed data: URL" do
      body = <<-JSON
      {
        "choices": [
          {"message": {"images": [{"image_url": {"url": "data:image/png;notbase64"}}]}}
        ]
      }
      JSON
      expect_raises(CrystalLLM::Error, /Invalid data URL format/) do
        configured_openrouter.parse_image_response(build_response(200, body), model: "m")
      end
    end
  end

  describe "#build_image_from_url" do
    it "parses a data URL into mime + base64 data" do
      image = configured_openrouter.build_image_from_url("data:image/jpeg;base64,Zm9v", "m")
      image.mime_type.should eq("image/jpeg")
      image.data.should eq("Zm9v")
      image.base64?.should be_true
    end
  end
end
