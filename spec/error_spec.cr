require "./spec_helper"

private def build_response(status : Int32, body : String) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://example.test")
  )
end

# Ports the contract of ruby_llm's lib/ruby_llm/error.rb (@ 1.15.0).
describe CrystalLLM::Error do
  it "uses an explicit message string" do
    err = CrystalLLM::Error.new("boom")
    err.message.should eq("boom")
    err.response.should be_nil
  end

  it "has no message when given neither response nor message" do
    # Crystal divergence: Ruby's StandardError#message returns the class name
    # ("RubyLLM::Error") when blank; Crystal's Exception#message is nil.
    CrystalLLM::Error.new.message.should be_nil
  end

  describe "with an HTTP response" do
    it "falls back to the response body for the message" do
      resp = build_response(500, "raw body")
      err = CrystalLLM::Error.new(resp)
      err.message.should eq("raw body")
      err.response.should be(resp)
    end

    it "prefers an explicit message over the response body" do
      resp = build_response(500, "raw body")
      err = CrystalLLM::Error.new(resp, "server error")
      err.message.should eq("server error")
      err.response.should be(resp)
    end
  end

  describe "HTTP status error classes" do
    it "all descend from Error so callers can rescue the base" do
      [
        CrystalLLM::BadRequestError, CrystalLLM::ForbiddenError,
        CrystalLLM::ContextLengthExceededError, CrystalLLM::OverloadedError,
        CrystalLLM::PaymentRequiredError, CrystalLLM::RateLimitError,
        CrystalLLM::ServerError, CrystalLLM::ServiceUnavailableError,
        CrystalLLM::UnauthorizedError,
      ].each do |klass|
        klass.new("x").should be_a(CrystalLLM::Error)
      end
    end

    it "inherits the string-argument constructor (response stays nil)" do
      err = CrystalLLM::BadRequestError.new("bad request")
      err.message.should eq("bad request")
      err.response.should be_nil
    end

    it "is rescuable as the base Error" do
      rescued = false
      begin
        raise CrystalLLM::RateLimitError.new("slow down")
      rescue ex : CrystalLLM::Error
        rescued = true
        ex.message.should eq("slow down")
      end
      rescued.should be_true
    end
  end

  describe "non-HTTP errors" do
    it "do NOT descend from Error (mirrors ruby_llm: siblings under StandardError)" do
      CrystalLLM::ConfigurationError.new("x").is_a?(CrystalLLM::Error).should be_false
      CrystalLLM::PromptNotFoundError.new("x").is_a?(CrystalLLM::Error).should be_false
      CrystalLLM::InvalidRoleError.new("x").is_a?(CrystalLLM::Error).should be_false
      CrystalLLM::InvalidToolChoiceError.new("x").is_a?(CrystalLLM::Error).should be_false
      CrystalLLM::ModelNotFoundError.new("x").is_a?(CrystalLLM::Error).should be_false
    end
  end

  describe CrystalLLM::UnsupportedAttachmentError do
    it "names the unsupported type and appends guidance" do
      err = CrystalLLM::UnsupportedAttachmentError.new("image/heic")
      err.message.should eq(
        "Unsupported attachment type: image/heic. #{CrystalLLM::UnsupportedAttachmentError::GUIDANCE}"
      )
    end

    it "omits the type when none is given" do
      err = CrystalLLM::UnsupportedAttachmentError.new
      err.message.should eq(
        "Unsupported attachment type. #{CrystalLLM::UnsupportedAttachmentError::GUIDANCE}"
      )
    end
  end
end
