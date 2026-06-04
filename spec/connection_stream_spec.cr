require "./spec_helper"
require "http/server"
require "../src/crystal_llm/providers/openai"

# REGRESSION (BUG 4, connection half): a non-200 STREAM response must map to the
# same CrystalLLM error as a non-streaming #post. crest raises Crest::RequestFailed
# (before yielding a body) on a 4xx/5xx; Connection#post_stream must rescue it and
# call map_error, exactly like #post. Before the fix, post_stream had no rescue and
# the raw Crest::RequestFailed leaked out.
#
# Driven against a tiny in-process HTTP server (no external network), mirroring the
# local-server pattern in spec/ruby_llm/image_spec.cr.
private def openai_provider : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "test"
  CrystalLLM::Providers::OpenAI.new(config)
end

describe CrystalLLM::Connection do
  describe "#post_stream error mapping" do
    it "maps a 429 stream response to a CrystalLLM::RateLimitError" do
      server = HTTP::Server.new do |context|
        context.response.status_code = 429
        context.response.content_type = "application/json"
        context.response.print(%({"error":{"message":"slow down"}}))
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      begin
        provider = openai_provider
        # post_stream does not go through with_retries, so the mapped error surfaces
        # immediately (a 429 here maps to RateLimitError via map_error).
        connection = CrystalLLM::Connection.new(provider, provider.config)
        url = "http://#{address.address}:#{address.port}/v1/chat/completions"

        expect_raises(CrystalLLM::RateLimitError) do
          connection.post_stream(url, "{}") { |_| }
        end
      ensure
        server.close
      end
    end

    it "maps a 401 stream response to a CrystalLLM::UnauthorizedError" do
      server = HTTP::Server.new do |context|
        context.response.status_code = 401
        context.response.content_type = "application/json"
        context.response.print(%({"error":{"message":"bad key"}}))
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      begin
        provider = openai_provider
        connection = CrystalLLM::Connection.new(provider, provider.config)
        url = "http://#{address.address}:#{address.port}/v1/chat/completions"

        expect_raises(CrystalLLM::UnauthorizedError) do
          connection.post_stream(url, "{}") { |_| }
        end
      ensure
        server.close
      end
    end
  end
end
