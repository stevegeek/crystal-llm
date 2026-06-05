require "./spec_helper"
require "http/server"
require "../src/crystal_llm/providers/openai"

# Two gaps, both driven against a tiny in-process HTTP server (no external network),
# mirroring the local-server pattern in spec/connection_stream_spec.cr.
#
#   * #3 (untested): Connection#with_retries had ZERO coverage. We exercise the
#     retry/backoff loop end-to-end: transient 503s are retried until a 200, the
#     retry BUDGET is exactly max_retries+1 attempts, and a non-retryable 400
#     surfaces immediately with no retries.
#
#   * DIVERGENCE 16 (header precedence): Connection now merges provider/auth headers
#     LAST (`headers.merge(provider_headers)`), so a caller's `with_headers` value
#     cannot clobber the provider's Authorization header — matching ruby_llm
#     (`req.headers.merge! provider_headers`). A caller header for a DISTINCT key is
#     still sent; a caller value colliding with the provider's auth header loses.

private def fast_retry_provider(max_retries : Int32 = 3) : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "secret-key"
  config.max_retries = max_retries
  config.retry_interval = 0.001   # keep the suite fast
  config.retry_backoff_factor = 1 # no exponential growth in tests
  config.retry_interval_randomness = 0.0
  CrystalLLM::Providers::OpenAI.new(config)
end

describe CrystalLLM::Connection do
  describe "#with_retries (retry/backoff loop)" do
    it "retries transient 503s and returns the 200 once the server recovers" do
      attempts = 0
      server = HTTP::Server.new do |ctx|
        attempts += 1
        if attempts <= 2
          ctx.response.status_code = 503
          ctx.response.print(%({"error":{"message":"unavailable"}}))
        else
          ctx.response.status_code = 200
          ctx.response.print(%({"ok":true}))
        end
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      begin
        provider = fast_retry_provider(max_retries: 3)
        connection = CrystalLLM::Connection.new(provider, provider.config)
        url = "http://#{addr.address}:#{addr.port}/v1/chat/completions"

        response = connection.post(url, "{}")
        response.status_code.should eq(200)
        attempts.should eq(3) # 2 failures + 1 success
      ensure
        server.close
      end
    end

    it "surfaces the mapped error after exactly max_retries+1 attempts when the budget is exceeded" do
      attempts = 0
      server = HTTP::Server.new do |ctx|
        attempts += 1
        ctx.response.status_code = 503
        ctx.response.print(%({"error":{"message":"still down"}}))
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      begin
        provider = fast_retry_provider(max_retries: 2)
        connection = CrystalLLM::Connection.new(provider, provider.config)
        url = "http://#{addr.address}:#{addr.port}/v1/chat/completions"

        expect_raises(CrystalLLM::ServiceUnavailableError) do
          connection.post(url, "{}")
        end
        attempts.should eq(3) # max_retries(2) + 1 initial = 3 total attempts
      ensure
        server.close
      end
    end

    it "does not retry a non-retryable 400 (surfaces immediately on the first attempt)" do
      attempts = 0
      server = HTTP::Server.new do |ctx|
        attempts += 1
        ctx.response.status_code = 400
        ctx.response.print(%({"error":{"message":"bad request"}}))
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      begin
        provider = fast_retry_provider(max_retries: 3)
        connection = CrystalLLM::Connection.new(provider, provider.config)
        url = "http://#{addr.address}:#{addr.port}/v1/chat/completions"

        expect_raises(CrystalLLM::BadRequestError) do
          connection.post(url, "{}")
        end
        attempts.should eq(1) # no retries for a 400
      ensure
        server.close
      end
    end
  end

  describe "header precedence (DIVERGENCE 16)" do
    it "sends a distinct caller header AND keeps the provider's Authorization uncloberrable" do
      received = {} of String => String
      server = HTTP::Server.new do |ctx|
        ctx.request.headers.each { |k, v| received[k] = v.first }
        ctx.response.status_code = 200
        ctx.response.print(%({"ok":true}))
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      begin
        provider = fast_retry_provider
        connection = CrystalLLM::Connection.new(provider, provider.config)
        url = "http://#{addr.address}:#{addr.port}/v1/chat/completions"

        # Caller supplies a distinct header AND attempts to override Authorization.
        connection.post(url, "{}", {
          "X-Caller-Header" => "present",
          "Authorization"   => "Bearer attacker-override",
        })

        received["X-Caller-Header"]?.should eq("present")         # distinct caller header is sent
        received["Authorization"]?.should eq("Bearer secret-key") # provider/auth header wins
      ensure
        server.close
      end
    end
  end
end
