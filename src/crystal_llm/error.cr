# ported from lib/ruby_llm/error.rb @ ruby_llm 1.16.0
require "crest"

module CrystalLLM
  # Wraps API errors from different providers into a consistent format with
  # helpful error messages.
  #
  # Ruby's `Error.new(response_or_string, message)` dual signature becomes two
  # Crystal constructors: one taking the HTTP response, one taking a bare message.
  class Error < Exception
    getter response : Crest::Response?

    def initialize(@response : Crest::Response? = nil, message : String? = nil)
      super(message || @response.try(&.body))
    end

    # Mirrors `RubyLLM::Error.new("message")`.
    def initialize(message : String)
      @response = nil
      super(message)
    end
  end

  # Error classes for non-HTTP errors (siblings of Error, not subclasses —
  # matching ruby_llm, where these descend from StandardError directly).
  class ConfigurationError < Exception; end

  class PromptNotFoundError < Exception; end

  class InvalidRoleError < Exception; end

  class InvalidToolChoiceError < Exception; end

  class ModelNotFoundError < Exception; end

  # Raised by the typed structured-output hatch (`Chat#ask_as`) when the assistant
  # response content is not the expected JSON String (e.g. a tool-call message or
  # structured Content), so `T.from_json` cannot run.
  class SchemaResponseError < Exception; end

  # Raised when CrystalLLM cannot format an attachment for the selected provider.
  class UnsupportedAttachmentError < Exception
    GUIDANCE = "Consider using a model that supports this attachment type."

    def initialize(type : String? = nil)
      message = "Unsupported attachment type"
      message = "#{message}: #{type}" if type
      super("#{message}. #{GUIDANCE}")
    end
  end

  # Error classes for different HTTP status codes.
  class BadRequestError < Error; end

  class ForbiddenError < Error; end

  class ContextLengthExceededError < Error; end

  class OverloadedError < Error; end

  class PaymentRequiredError < Error; end

  class RateLimitError < Error; end

  class ServerError < Error; end

  class ServiceUnavailableError < Error; end

  class UnauthorizedError < Error; end
end
