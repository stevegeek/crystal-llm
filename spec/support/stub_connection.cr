# Offline test support: a `Connection` subclass that returns canned
# `Crest::Response` objects instead of performing HTTP. Injected into a real
# provider via the `Provider#connection=` test affordance so the FULL completion
# path (render_payload -> connection.post / post_stream -> parse_completion_response
# -> Message) runs with NO network.
#
# require this from an integration spec (NOT from spec_helper) so the production
# `src/crystal_llm` build never pulls in test scaffolding.
require "crest"
require "http"
require "../../src/crystal_llm/connection"

module CrystalLLM::Spec
  # A `Connection` that never touches the network. `post`/`get` return a queued
  # canned response (FIFO); `post_stream` replays a queued SSE body line by line
  # into the block the way crest's streaming `post` would. The responses are set
  # up per-test; calls are recorded so specs can assert what the provider sent.
  class StubConnection < CrystalLLM::Connection
    # Queue of canned bodies for `post`/`get`, consumed FIFO. Each entry is a
    # {status, body} tuple.
    getter queued_responses : Array(Tuple(Int32, String))
    # Queue of canned SSE bodies for `post_stream`, consumed FIFO. Each entry is
    # the raw SSE text (with `data: ...\n\n` events).
    getter queued_streams : Array(String)
    # Recorded {url, payload} of each post (for assertions on the wire request).
    getter posts : Array(Tuple(String, String))
    # Recorded {url, payload} of each streaming post.
    getter stream_posts : Array(Tuple(String, String))
    # Recorded {url, form} of each multipart post (for assertions on the file part
    # + scalar fields without sending anything over the wire).
    getter multipart_posts : Array(Tuple(String, Hash(String, Crest::ParamsValue)))

    def initialize(provider : CrystalLLM::Provider, config : CrystalLLM::Configuration)
      super(provider, config)
      @queued_responses = [] of Tuple(Int32, String)
      @queued_streams = [] of String
      @posts = [] of Tuple(String, String)
      @stream_posts = [] of Tuple(String, String)
      @multipart_posts = [] of Tuple(String, Hash(String, Crest::ParamsValue))
    end

    # Queue a canned non-streaming response (FIFO across post/get).
    def stub_response(body : String, status : Int32 = 200) : self
      @queued_responses << {status, body}
      self
    end

    # Queue a canned SSE stream body for the next `post_stream`.
    def stub_stream(sse_body : String) : self
      @queued_streams << sse_body
      self
    end

    def post(url : String, payload : String,
             headers : Hash(String, String) = {} of String => String) : Crest::Response
      @posts << {url, payload}
      next_response
    end

    def get(url : String,
            headers : Hash(String, String) = {} of String => String) : Crest::Response
      next_response
    end

    # Record the multipart form (so specs can assert the file part / scalar fields)
    # and return a canned response — no HTTP. The caller still owns/closes any File
    # parts in the form, exactly as in production.
    def post_multipart(url : String,
                       form : Hash(String, Crest::ParamsValue),
                       headers : Hash(String, String) = {} of String => String) : Crest::Response
      @multipart_posts << {url, form}
      next_response
    end

    def post_stream(url : String, payload : String,
                    headers : Hash(String, String) = {} of String => String,
                    &block : Crest::Response ->) : Nil
      @stream_posts << {url, payload}
      if @queued_streams.empty?
        raise "StubConnection ran out of queued SSE streams (queue a stub_stream)"
      end
      block.call(build_stream_response(@queued_streams.shift))
    end

    private def next_response : Crest::Response
      if @queued_responses.empty?
        raise "StubConnection ran out of queued responses (queue a stub_response)"
      end
      status, body = @queued_responses.shift
      build_response(status, body)
    end

    # Build a Crest::Response over an in-memory body (mirrors spec/provider_spec.cr).
    private def build_response(status : Int32, body : String) : Crest::Response
      Crest::Response.new(
        HTTP::Client::Response.new(status, body: body),
        Crest::Request.new(:post, "http://stub.test")
      )
    end

    # Build a Crest::Response whose `body_io` replays the SSE text, the way the
    # Streaming mixin reads a real crest streaming response (`body_io.each_line`).
    private def build_stream_response(sse_body : String) : Crest::Response
      Crest::Response.new(
        HTTP::Client::Response.new(200, body_io: IO::Memory.new(sse_body)),
        Crest::Request.new(:post, "http://stub.test")
      )
    end
  end
end
