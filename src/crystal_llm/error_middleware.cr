# ported from lib/ruby_llm/error_middleware.rb @ ruby_llm 1.15.0
require "crest"
require "./error"

module CrystalLLM
  # Maps provider HTTP error responses to CrystalLLM errors. ruby_llm implements
  # this as Faraday middleware; here it's a function the Connection calls with the
  # response status, the provider-extracted error `message`, and the raw `response`
  # (carried on the raised error for inspection).
  module ErrorMiddleware
    extend self

    CONTEXT_LENGTH_PATTERNS = [
      /context length/i,
      /context window/i,
      /maximum context/i,
      /request too large/i,
      /too many tokens/i,
      /token count exceeds/i,
      /input[_\s-]?token/i,
      /input or output tokens? must be reduced/i,
      /reduce the length of messages/i,
    ]

    # Raises the mapped error for 4xx/5xx statuses; returns `message` for 2xx/3xx.
    # (ruby_llm disables rubocop's complexity cop here too — it's a status dispatch.)
    # ameba:disable Metrics/CyclomaticComplexity
    def parse_error(status : Int32, message : String? = nil, response : Crest::Response? = nil) : String?
      case status
      when 200..399
        message
      when 400
        if context_length_exceeded?(message)
          raise ContextLengthExceededError.new(response, message || "Context length exceeded")
        end
        raise BadRequestError.new(response, message || "Invalid request - please check your input")
      when 401
        raise UnauthorizedError.new(response, message || "Invalid API key - check your credentials")
      when 402
        raise PaymentRequiredError.new(response, message || "Payment required - please top up your account")
      when 403
        raise ForbiddenError.new(response, message || "Forbidden - you do not have permission to access this resource")
      when 429
        if context_length_exceeded?(message)
          raise ContextLengthExceededError.new(response, message || "Context length exceeded")
        end
        raise RateLimitError.new(response, message || "Rate limit exceeded - please wait a moment")
      when 500
        raise ServerError.new(response, message || "API server error - please try again")
      when 502..504
        raise ServiceUnavailableError.new(response, message || "API server unavailable - please try again later")
      when 529
        raise OverloadedError.new(response, message || "Service overloaded - please try again later")
      else
        raise Error.new(response, message || "An unknown error occurred")
      end
    end

    private def context_length_exceeded?(message : String?) : Bool
      return false if message.nil? || message.empty?

      CONTEXT_LENGTH_PATTERNS.any? { |pattern| message.matches?(pattern) }
    end
  end
end
