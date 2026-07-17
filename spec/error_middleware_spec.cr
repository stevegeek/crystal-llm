require "./spec_helper"

# Ports ruby_llm spec/ruby_llm/error_middleware_spec.rb (@ 1.15.0).
# The provider's `parse_error(response)` extraction happens at the call site, so the
# Crystal port takes the already-extracted message + status directly.
describe CrystalLLM::ErrorMiddleware do
  describe ".parse_error" do
    it "maps 502/503/504 to ServiceUnavailableError" do
      {502, 503, 504}.each do |status|
        expect_raises(CrystalLLM::ServiceUnavailableError) do
          CrystalLLM::ErrorMiddleware.parse_error(status, "down")
        end
      end
    end

    it "maps context-length-like 429 errors to ContextLengthExceededError" do
      expect_raises(CrystalLLM::ContextLengthExceededError) do
        CrystalLLM::ErrorMiddleware.parse_error(429, "Request too large for model")
      end
    end

    it "keeps regular 429 errors as RateLimitError" do
      expect_raises(CrystalLLM::RateLimitError) do
        CrystalLLM::ErrorMiddleware.parse_error(429, "Rate limit exceeded")
      end
    end

    it "maps context-length-like 400 errors to ContextLengthExceededError" do
      expect_raises(CrystalLLM::ContextLengthExceededError) do
        CrystalLLM::ErrorMiddleware.parse_error(400, "This model's maximum context length is 8192 tokens.")
      end
    end

    # Regression (BUG 8): the `/token count exceeds/i` pattern (8th of ruby's 9)
    # was missing, so a "token count exceeds" message fell through to BadRequest.
    it "maps a 'token count exceeds' 400 to ContextLengthExceededError" do
      expect_raises(CrystalLLM::ContextLengthExceededError) do
        CrystalLLM::ErrorMiddleware.parse_error(400, "The token count exceeds the model's limit")
      end
    end

    # ruby_llm a66e7005: Anthropic's 400 "prompt is too long: N tokens > max maximum"
    # was falling through to BadRequestError instead of ContextLengthExceededError.
    it "maps Anthropic's 'prompt is too long' 400 error to ContextLengthExceededError" do
      expect_raises(CrystalLLM::ContextLengthExceededError) do
        CrystalLLM::ErrorMiddleware.parse_error(400, "prompt is too long: 209025 tokens > 200000 maximum")
      end
    end

    it "keeps regular 400 errors as BadRequestError" do
      expect_raises(CrystalLLM::BadRequestError) do
        CrystalLLM::ErrorMiddleware.parse_error(400, "Invalid model specified")
      end
    end

    it "maps the remaining status codes to their error classes" do
      expect_raises(CrystalLLM::UnauthorizedError) { CrystalLLM::ErrorMiddleware.parse_error(401) }
      expect_raises(CrystalLLM::PaymentRequiredError) { CrystalLLM::ErrorMiddleware.parse_error(402) }
      expect_raises(CrystalLLM::ForbiddenError) { CrystalLLM::ErrorMiddleware.parse_error(403) }
      expect_raises(CrystalLLM::ServerError) { CrystalLLM::ErrorMiddleware.parse_error(500) }
      expect_raises(CrystalLLM::OverloadedError) { CrystalLLM::ErrorMiddleware.parse_error(529) }
      expect_raises(CrystalLLM::Error) { CrystalLLM::ErrorMiddleware.parse_error(418) }
    end

    it "returns the message unchanged for success statuses" do
      CrystalLLM::ErrorMiddleware.parse_error(200, "ok").should eq("ok")
      CrystalLLM::ErrorMiddleware.parse_error(204, nil).should be_nil
    end
  end
end
