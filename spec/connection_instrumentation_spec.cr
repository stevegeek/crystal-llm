require "./spec_helper"
require "crest"
require "http"
require "../src/crystal_llm/providers/openai"

# Verifies Connection-level request instrumentation (ruby_llm connection.rb's
# `instrument_request`): `Connection#get`/`#post` wrap the HTTP call in a
# `request.crystal_llm` event carrying {provider, method, url}, recording the
# response status afterward. NO network: a Connection subclass overrides the
# private `request` hook to hand back a canned Crest::Response while keeping the
# real get/post -> instrument_request path.

# Records every (name, payload) observed, snapshotting payload AFTER the wrapped
# block attached its result-side keys (e.g. status).
private class RecordingInstrumenter < CrystalLLM::Instrumenter
  getter events : Array({String, CrystalLLM::Instrumentation::Payload})

  def initialize
    @events = [] of {String, CrystalLLM::Instrumentation::Payload}
  end

  def instrument(name : String, payload : CrystalLLM::Instrumentation::Payload,
                 &block : CrystalLLM::Instrumentation::Payload -> T) : T forall T
    result = block.call(payload)
    @events << {name, payload.dup}
    result
  end

  def event(name : String) : CrystalLLM::Instrumentation::Payload?
    @events.find { |(n, _)| n == name }.try(&.[1])
  end
end

# A Connection whose private `request` hook returns a canned 200 response instead
# of doing I/O, so the real `get`/`post` (and their `instrument_request` wrapper)
# run offline.
private class CannedConnection < CrystalLLM::Connection
  def initialize(provider : CrystalLLM::Provider, config : CrystalLLM::Configuration)
    super(provider, config)
  end

  private def request(method : Symbol, url : String, payload : String?,
                      headers : Hash(String, String)) : Crest::Response
    Crest::Response.new(
      HTTP::Client::Response.new(200, body: %({"ok":true})),
      Crest::Request.new(method, "http://stub.test")
    )
  end
end

private def openai_provider : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "test"
  CrystalLLM::Providers::OpenAI.new(config)
end

describe CrystalLLM::Connection do
  describe "request instrumentation" do
    it "emits a request.crystal_llm event with provider/method/url and status for #post" do
      provider = openai_provider
      provider.config.instrumenter = (recorder = RecordingInstrumenter.new)
      connection = CannedConnection.new(provider, provider.config)

      connection.post("/v1/chat/completions", "{}")

      event = recorder.event("request.crystal_llm")
      event.should_not be_nil
      raise "no request.crystal_llm event recorded" unless event
      event["provider"].should eq(provider.slug)
      event["method"].should eq("post")
      event["url"].should eq("/v1/chat/completions")
      event["status"].should eq(200)
    end

    it "emits a request.crystal_llm event for #get" do
      provider = openai_provider
      provider.config.instrumenter = (recorder = RecordingInstrumenter.new)
      connection = CannedConnection.new(provider, provider.config)

      connection.get("/v1/models")

      event = recorder.event("request.crystal_llm")
      raise "no request.crystal_llm event recorded" unless event
      event["method"].should eq("get")
      event["url"].should eq("/v1/models")
      event["status"].should eq(200)
    end

    it "runs transparently (no event) when no instrumenter is configured" do
      provider = openai_provider
      provider.config.instrumenter.should be_nil
      connection = CannedConnection.new(provider, provider.config)

      # Should not raise and should return the canned response.
      response = connection.post("/v1/chat/completions", "{}")
      response.status_code.should eq(200)
    end
  end
end
