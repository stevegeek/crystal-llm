# REAL-DATA parser tests for the Bedrock provider.
#
# Driven by harvested VCR cassette fixtures at spec/fixtures/cassettes/bedrock/.
# These are ACTUAL recorded AWS Bedrock Converse-API responses (from ruby_llm's
# VCR cassettes), not hand-written. The point is to validate our parser against
# real-world shapes.
#
# Bedrock only has chat_*.json fixtures (no stream/embedding/image/moderation/
# transcription — Bedrock never ported those in ruby_llm either; see bedrock.cr
# header "DEFERRED").
#
# FIXTURE NOTE (see findings): chat_1.json and chat_4.json are stored base64-
# encoded in the harvest, while chat_2/chat_3 are raw JSON. Real Bedrock HTTP
# response bodies are raw JSON, so the test normalizes the fixture (decode base64
# when the body is not valid JSON) before feeding the raw JSON the parser expects.
require "spec"
require "base64"
require "../../src/crystal_llm"

private FIXTURE_DIR = File.expand_path("../fixtures/cassettes/bedrock", __DIR__)

# Build a Bedrock provider whose required config keys are all set to "test"
# (NO network is performed — we only call the pure parse hooks).
private def build_bedrock_provider : CrystalLLM::Providers::Bedrock
  config = CrystalLLM::Configuration.new
  config.bedrock_api_key = "test"
  config.bedrock_secret_key = "test"
  config.bedrock_region = "us-east-1"
  config.bedrock_session_token = "test"
  CrystalLLM::Providers::Bedrock.new(config)
end

# Wrap a raw body string in a Crest::Response (mirrors spec/provider_spec.cr).
private def crest_response(body : String, status : Int32 = 200) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

# Read a cassette body, normalizing the harvest's mixed encoding: some bedrock
# fixtures are stored base64-encoded. Real Bedrock bodies are raw JSON, so decode
# base64 when the body isn't already valid JSON.
private def read_cassette_json(path : String) : String
  body = File.read(path).strip
  begin
    JSON.parse(body)
    body
  rescue JSON::ParseException
    decoded = Base64.decode_string(body)
    JSON.parse(decoded) # raises (failing the test) if this isn't JSON either
    decoded
  end
end

describe "Bedrock provider real-data parsing" do
  describe "parse_completion_response (chat_*.json)" do
    Dir.glob(File.join(FIXTURE_DIR, "chat_*.json")).sort.each do |path|
      name = File.basename(path)

      it "parses #{name} into a Message with content and token counts" do
        provider = build_bedrock_provider
        body = read_cassette_json(path)
        resp = crest_response(body)

        message = provider.parse_completion_response(resp)

        message.should be_a(CrystalLLM::Message)
        message.role.should eq(CrystalLLM::Role::Assistant)

        # Every bedrock chat fixture is a plain text answer (no tool_use blocks).
        content = message.content
        text = case content
               when String              then content
               when CrystalLLM::Content then content.text
               else                          nil
               end
        if text.nil?
          fail "#{name}: expected non-nil text content, got #{content.inspect}"
        end
        text.empty?.should be_false

        # Token counts must be populated from the `usage` block.
        input = message.input_tokens
        output = message.output_tokens
        if input.nil?
          fail "#{name}: expected input_tokens to be populated"
        end
        if output.nil?
          fail "#{name}: expected output_tokens to be populated"
        end
        input.should be > 0
        output.should be > 0

        # raw is the parsed body; modelId is absent in these fixtures (nil ok).
        message.raw.should_not be_nil
      end
    end
  end

  # Spot-check exact values from one known fixture so a parser regression that
  # silently zeroes/garbles tokens or text is caught (not just non-empty checks).
  describe "exact values" do
    it "chat_1: '2 + 2 equals **4**' answer, input 53 / output 63" do
      provider = build_bedrock_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "chat_1.json"))
      message = provider.parse_completion_response(crest_response(body))

      content = message.content
      text = content.is_a?(String) ? content : content.as(CrystalLLM::Content).text
      if text.nil?
        fail "chat_1: expected non-nil text content"
      end
      text.should contain("2 + 2 equals")
      text.should contain("**4**")

      message.input_tokens.should eq(53)
      message.output_tokens.should eq(63)
      message.tool_calls.should be_nil
    end

    it "chat_2: subtracts cache tokens from inputTokens (real cacheRead/Write=0 path)" do
      provider = build_bedrock_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "chat_2.json"))
      message = provider.parse_completion_response(crest_response(body))

      # usage: inputTokens 2690, cacheReadInputTokens 0, cacheWriteInputTokens 0
      # -> input_tokens = 2690 - 0 - 0 = 2690
      message.input_tokens.should eq(2690)
      message.output_tokens.should eq(154)
      message.cached_tokens.should eq(0)
      message.cache_creation_tokens.should eq(0)
    end
  end
end
