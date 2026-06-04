# ported from lib/ruby_llm/connection.rb @ ruby_llm 1.15.0
require "crest"
require "json"
require "./error"
require "./error_middleware"

module CrystalLLM
  # Manages HTTP connections to providers. ruby_llm builds a Faraday stack
  # (timeout + logging + retry + json + the llm_errors middleware); here we wrap
  # crest and implement retry + error mapping ourselves (crest has neither).
  class Connection
    getter config : Configuration

    RETRYABLE_STATUSES = {429, 500, 502, 503, 504, 529}

    def initialize(@provider : Provider, @config : Configuration)
      @api_base = @provider.api_base
    end

    # A bare connection for simple GETs (e.g. fetching attachment URLs), with no
    # provider headers — ruby_llm's `Connection.basic`.
    def self.basic_get(url : String) : Crest::Response
      Crest.get(url)
    end

    def get(url : String, headers : Hash(String, String) = {} of String => String) : Crest::Response
      with_retries do
        request(:get, full_url(url), nil, headers)
      end
    end

    def post(url : String, payload : String, headers : Hash(String, String) = {} of String => String) : Crest::Response
      with_retries do
        request(:post, full_url(url), payload, headers)
      end
    end

    # Multipart POST: sends a `multipart/form-data` body via crest. *form* is a flat
    # Hash whose values are crest `ParamsValue`s — String fields plus IO/File parts
    # (crest emits any IO value as a file part, sniffing its filename/MIME). Used for
    # the file-upload network paths (audio transcription, image editing) that the
    # JSON `#post` cannot express. Same retry + error-map wrapping as `#post`.
    def post_multipart(url : String,
                       form : Hash(String, Crest::ParamsValue),
                       headers : Hash(String, String) = {} of String => String) : Crest::Response
      with_retries do
        multipart_request(full_url(url), form, headers)
      end
    end

    # Streaming POST: yields the crest response so the caller can read body_io.
    def post_stream(url : String, payload : String, headers : Hash(String, String) = {} of String => String, &block : Crest::Response ->) : Nil
      hdrs = provider_headers.merge(headers)
      begin
        Crest.post(full_url(url), payload, headers: hdrs, json: false, read_timeout: @config.request_timeout.seconds) do |response|
          block.call(response)
        end
      rescue ex : Crest::RequestFailed
        # A non-200 stream response (crest raises before yielding the body) maps to
        # the same CrystalLLM error as a non-streaming #post.
        map_error(ex.response)
      end
    end

    private def request(method : Symbol, url : String, payload : String?, headers : Hash(String, String)) : Crest::Response
      hdrs = provider_headers.merge(headers)
      begin
        case method
        when :get
          Crest.get(url, headers: hdrs, read_timeout: @config.request_timeout.seconds)
        else
          Crest.post(url, payload || "", headers: hdrs, json: false, read_timeout: @config.request_timeout.seconds)
        end
      rescue ex : Crest::RequestFailed
        map_error(ex.response)
      end
    end

    private def multipart_request(url : String,
                                  form : Hash(String, Crest::ParamsValue),
                                  headers : Hash(String, String)) : Crest::Response
      hdrs = provider_headers.merge(headers)
      begin
        # `multipart: true` forces a multipart body even if no value is an IO
        # (so a fields-only edit form still posts as form-data, matching ruby_llm).
        Crest.post(url, form, headers: hdrs, multipart: true, read_timeout: @config.request_timeout.seconds)
      rescue ex : Crest::RequestFailed
        map_error(ex.response)
      end
    end

    # Maps a failed crest response to a CrystalLLM error (raises). Mirrors
    # ruby_llm's llm_errors middleware: extract the provider message, then dispatch.
    private def map_error(response : Crest::Response) : NoReturn
      message = @provider.parse_error(response)
      ErrorMiddleware.parse_error(response.status_code, message, response)
      raise Error.new(response) # unreachable for mapped statuses; satisfies NoReturn
    end

    # Retries idempotent + POST requests on transient failures, with exponential
    # backoff + jitter (mirrors faraday-retry's config knobs).
    private def with_retries(& : -> Crest::Response) : Crest::Response
      attempt = 0
      loop do
        return yield
      rescue ex : RateLimitError | ServerError | ServiceUnavailableError | OverloadedError | IO::Error
        attempt += 1
        raise ex if attempt > @config.max_retries

        sleep(retry_delay(attempt).seconds)
      end
    end

    private def retry_delay(attempt : Int32) : Float64
      base = @config.retry_interval * (@config.retry_backoff_factor.to_f ** (attempt - 1))
      jitter = base * @config.retry_interval_randomness * deterministic_jitter(attempt)
      base + jitter
    end

    # A bounded, dependency-free jitter in [0, 1) (Random is unavailable in some
    # contexts; the exact value is unimportant — only that retries are spread).
    private def deterministic_jitter(attempt : Int32) : Float64
      ((attempt * 2654435761_u32) % 1000) / 1000.0
    end

    private def provider_headers : Hash(String, String)
      @provider.headers
    end

    private def full_url(url : String) : String
      return url if url.starts_with?("http://") || url.starts_with?("https://")

      "#{@api_base.chomp('/')}/#{url.lchop('/')}"
    end
  end
end
