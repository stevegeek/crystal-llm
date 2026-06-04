# REAL-DATA parser tests for the Perplexity (Sonar) provider.
#
# Driven by harvested VCR cassette fixtures at spec/fixtures/cassettes/perplexity/.
# These are ACTUAL recorded Perplexity API responses (from ruby_llm's VCR
# cassettes), not hand-written. Perplexity is OpenAI-compatible, so the parser
# under test is the inherited OpenAI #parse_completion_response / #build_chunk —
# the point is to validate it against real Perplexity wire shapes.
#
# FIXTURES PRESENT (only chat_* exist for this provider — no embedding/image/
# moderation/transcription; ruby_llm's Perplexity ports CHAT only):
#   - chat_1.json / chat_2.json / chat_4.json: single JSON completion responses,
#     base64-encoded in the harvest. chat_4 carries <think>...</think> reasoning
#     content (model sonar-reasoning-pro) that the parser must strip.
#   - chat_3.json: a base64-encoded SSE *stream* (98 `data:` events, CRLF-delimited)
#     rather than a single completion JSON — so it drives the streaming path.
#
# The whole harvest is base64-encoded; we decode before feeding the parser the raw
# body it expects (a real Perplexity body would be raw JSON / raw SSE text).
require "spec"
require "base64"
require "../../src/crystal_llm"
require "../support/stub_connection"

private FIXTURE_DIR = File.expand_path("../fixtures/cassettes/perplexity", __DIR__)

# Build a Perplexity provider with its required config key set to "test"
# (NO network — we only exercise the pure parse hooks / the stubbed stream path).
private def build_perplexity_provider : CrystalLLM::Providers::Perplexity
  config = CrystalLLM::Configuration.new
  config.perplexity_api_key = "test"
  CrystalLLM::Providers::Perplexity.new(config)
end

# Wrap a raw body string in a Crest::Response (mirrors spec/provider_spec.cr).
private def crest_response(body : String, status : Int32 = 200) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

# Read a cassette body, decoding the harvest's base64 wrapping. Returns the raw
# provider body (JSON for completions, SSE text for the stream fixture).
private def read_cassette(path : String) : String
  Base64.decode_string(File.read(path).strip)
end

# Pull the plain text out of a Message's content union, or nil.
private def message_text(message : CrystalLLM::Message) : String?
  case content = message.content
  when String              then content
  when CrystalLLM::Content then content.text
  else                          nil
  end
end

# Completion fixtures (single JSON) vs the stream fixture (SSE text).
private COMPLETION_FIXTURES = ["chat_1.json", "chat_2.json", "chat_4.json"]
private STREAM_FIXTURE      = "chat_3.json"

describe "Perplexity provider real-data parsing" do
  describe "parse_completion_response (chat_*.json single completions)" do
    COMPLETION_FIXTURES.each do |name|
      it "parses #{name} into an assistant Message with content + token counts" do
        provider = build_perplexity_provider
        body = read_cassette(File.join(FIXTURE_DIR, name))
        message = provider.parse_completion_response(crest_response(body))

        message.should be_a(CrystalLLM::Message)
        message.role.should eq(CrystalLLM::Role::Assistant)

        text = message_text(message)
        if text.nil?
          fail "#{name}: expected non-nil text content, got #{message.content.inspect}"
        end
        text.empty?.should be_false

        # <think> reasoning must be stripped out of the visible content.
        text.includes?("<think>").should be_false

        # Token counts come from the `usage` block (prompt/completion tokens).
        input = message.input_tokens
        output = message.output_tokens
        if input.nil?
          fail "#{name}: expected input_tokens populated"
        end
        if output.nil?
          fail "#{name}: expected output_tokens populated"
        end
        input.should be > 0
        output.should be > 0

        message.tool_calls.should be_nil
        message.raw.should_not be_nil
        message.model_id.should_not be_nil
      end
    end
  end

  # Spot-check exact values so a regression that zeroes/garbles tokens or text is
  # caught (not just the non-empty guards above).
  describe "exact values" do
    it "chat_1: Ruby license answer, input 536 / output 297, model sonar" do
      provider = build_perplexity_provider
      body = read_cassette(File.join(FIXTURE_DIR, "chat_1.json"))
      message = provider.parse_completion_response(crest_response(body))

      text = message_text(message)
      if text.nil?
        fail "chat_1: expected non-nil text content"
      end
      text.should contain("Ruby")

      message.input_tokens.should eq(536)
      message.output_tokens.should eq(297)
      message.model_id.should eq("sonar")
    end

    it "chat_4: strips <think> reasoning, keeps the visible answer (input 9)" do
      provider = build_perplexity_provider
      body = read_cassette(File.join(FIXTURE_DIR, "chat_4.json"))
      message = provider.parse_completion_response(crest_response(body))

      text = message_text(message)
      if text.nil?
        fail "chat_4: expected non-nil text content after <think> stripping"
      end
      # The raw fixture content begins with "<think>...": after stripping the
      # tag the visible answer (about 5 + 3) must remain, tag-free.
      text.includes?("<think>").should be_false
      text.includes?("</think>").should be_false
      text.empty?.should be_false

      message.input_tokens.should eq(9)
      message.model_id.should eq("sonar-reasoning-pro")
    end
  end

  describe "streaming (chat_3.json — real SSE stream)" do
    it "accumulates real SSE deltas into a Message with content + final usage" do
      provider = build_perplexity_provider
      sse_body = read_cassette(File.join(FIXTURE_DIR, STREAM_FIXTURE))

      # Drive the full streaming path through the offline StubConnection: it
      # replays the real SSE body into post_stream exactly as crest would.
      stub = CrystalLLM::Spec::StubConnection.new(provider, provider.config)
      stub.stub_stream(sse_body)
      provider.connection = stub

      payload = %({"model":"sonar","stream":true})
      collected = [] of CrystalLLM::Chunk
      message = provider.stream_response(payload) do |chunk|
        collected << chunk
      end

      # Real stream has many delta events; at least some carried content.
      collected.empty?.should be_false

      text = message_text(message)
      if text.nil?
        fail "chat_3: expected accumulated stream content, got nil"
      end
      text.empty?.should be_false
      # The recorded answer counts "1, 2, 3"; sanity-check a stable substring.
      text.should contain("3")

      # Final usage event (Perplexity sends usage with the terminal chunk).
      output = message.output_tokens
      if output.nil?
        fail "chat_3: expected output_tokens from the terminal usage event"
      end
      output.should be > 0

      message.model_id.should eq("sonar")
      message.tool_calls.should be_nil
    end
  end
end
