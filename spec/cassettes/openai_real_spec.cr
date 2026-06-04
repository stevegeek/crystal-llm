# REAL-DATA parser tests for the OpenAI provider.
#
# Driven by harvested VCR cassette fixtures at spec/fixtures/cassettes/openai/.
# These are ACTUAL recorded OpenAI API responses (from ruby_llm's VCR cassettes),
# not hand-written. The point is to validate our parsers against real-world shapes:
#   - chat_*.json          -> parse_completion_response  (text + tool_calls + tokens)
#   - stream_*.sse         -> stream_response / build_chunk (accumulated Message)
#   - embedding_*.json     -> parse_embedding_response
#   - image_*.json         -> parse_image_response
#   - moderation_*.json    -> parse_moderation_response
#   - transcription_*.json -> parse_transcription_response
#
# FIXTURE NOTE (see findings): some harvested bodies are stored base64-encoded
# (e.g. chat_2.json). Real OpenAI HTTP response bodies are raw JSON, so the test
# normalizes the fixture (decode base64 when the body is not valid JSON) before
# feeding the raw JSON the parser expects. SSE bodies are fed verbatim.
require "spec"
require "base64"
require "../support/stub_connection"
require "../../src/crystal_llm"

private FIXTURE_DIR = File.expand_path("../fixtures/cassettes/openai", __DIR__)

# Build an OpenAI provider whose required config key is set to "test"
# (NO network is performed — we only call pure parse hooks, or stub the
# Connection for the streaming path).
private def build_openai_provider : CrystalLLM::Providers::OpenAI
  config = CrystalLLM::Configuration.new
  config.openai_api_key = "test"
  CrystalLLM::Providers::OpenAI.new(config)
end

# Wrap a raw body string in a Crest::Response (mirrors spec/provider_spec.cr).
private def crest_response(body : String, status : Int32 = 200) : Crest::Response
  Crest::Response.new(
    HTTP::Client::Response.new(status, body: body),
    Crest::Request.new(:get, "http://x")
  )
end

# Read a cassette body, normalizing the harvest's mixed encoding: some openai
# fixtures are stored base64-encoded. Real OpenAI bodies are raw JSON, so decode
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

private def message_text(message : CrystalLLM::Message) : String?
  content = message.content
  case content
  when String              then content
  when CrystalLLM::Content then content.text
  else                          nil
  end
end

describe "OpenAI provider real-data parsing" do
  describe "parse_completion_response (chat_*.json)" do
    Dir.glob(File.join(FIXTURE_DIR, "chat_*.json")).sort.each do |path|
      name = File.basename(path)

      it "parses #{name} into a Message with content/tool_calls and token counts" do
        provider = build_openai_provider
        body = read_cassette_json(path)
        message = provider.parse_completion_response(crest_response(body))

        message.should be_a(CrystalLLM::Message)
        message.role.should eq(CrystalLLM::Role::Assistant)

        # Each fixture is either a text answer or a tool-call response. Assert
        # that AT LEAST one of the two is populated (a real parse, not garbage).
        text = message_text(message)
        tool_calls = message.tool_calls
        has_text = !text.nil? && !text.empty?
        has_tools = !tool_calls.nil? && !tool_calls.empty?
        unless has_text || has_tools
          fail "#{name}: expected non-empty content OR tool_calls, got content=#{message.content.inspect} tool_calls=#{tool_calls.inspect}"
        end

        # Token counts come from the `usage` block (present in all fixtures).
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

        message.raw.should_not be_nil
        message.model_id.should_not be_nil
      end
    end
  end

  describe "chat exact values" do
    it "chat_1: Matz/Ruby text answer; reasoning tokens wired" do
      provider = build_openai_provider
      message = provider.parse_completion_response(
        crest_response(read_cassette_json(File.join(FIXTURE_DIR, "chat_1.json"))))

      text = message_text(message)
      if text.nil?
        fail "chat_1: expected non-nil text content"
      end
      text.should contain("Matsumoto")
      text.should contain("Ruby")
      message.tool_calls.should be_nil

      # usage: prompt 16, completion 231, total 247, cached 0, reasoning 192.
      # input = prompt - cacheRead - cacheWrite = 16 - 0 - 0 = 16
      # output = max(completion, total - prompt) = max(231, 231) = 231
      message.input_tokens.should eq(16)
      message.output_tokens.should eq(231)
      message.cached_tokens.should eq(0)
      message.thinking_tokens.should eq(192)
      message.reasoning_tokens.should eq(192)
      message.model_id.should eq("gpt-5-nano-2025-08-07")
    end

    it "chat_3: parses a real tool_call (calculator, expression 123*456)" do
      provider = build_openai_provider
      message = provider.parse_completion_response(
        crest_response(read_cassette_json(File.join(FIXTURE_DIR, "chat_3.json"))))

      # content is null on a tool-call response.
      tool_calls = message.tool_calls
      if tool_calls.nil?
        fail "chat_3: expected tool_calls, got nil"
      end
      tool_calls.size.should eq(1)

      call = tool_calls["call_dSDD7i1GOvG8xvULDlvK6UR4"]?
      if call.nil?
        fail "chat_3: expected a tool call keyed by its id, got #{tool_calls.keys.inspect}"
      end
      call.name.should eq("calculator")
      call.arguments["expression"]?.try(&.as_s).should eq("123*456")

      message.input_tokens.should eq(53)
      message.output_tokens.should eq(16)
    end

    it "chat_2 (base64-encoded fixture): decodes and parses the year answer" do
      provider = build_openai_provider
      message = provider.parse_completion_response(
        crest_response(read_cassette_json(File.join(FIXTURE_DIR, "chat_2.json"))))

      text = message_text(message)
      if text.nil?
        fail "chat_2: expected non-nil text content"
      end
      text.should contain("1995")
      message.input_tokens.should eq(63)
      message.output_tokens.should eq(218)
    end
  end

  describe "streaming (stream_*.sse) via stream_response + build_chunk" do
    Dir.glob(File.join(FIXTURE_DIR, "stream_*.sse")).sort.each do |path|
      name = File.basename(path)

      it "accumulates #{name} into a Message (content or tool_calls) + tokens" do
        provider = build_openai_provider
        config = CrystalLLM::Configuration.new
        config.openai_api_key = "test"
        stub = CrystalLLM::Spec::StubConnection.new(provider, config)
        provider.connection = stub

        sse_body = File.read(path)
        stub.stub_stream(sse_body)

        chunks = [] of CrystalLLM::Chunk
        final = provider.stream_response("{}") { |chunk| chunks << chunk }

        chunks.empty?.should be_false
        final.should be_a(CrystalLLM::Message)
        final.role.should eq(CrystalLLM::Role::Assistant)

        text = message_text(final)
        tool_calls = final.tool_calls
        has_text = !text.nil? && !text.empty?
        has_tools = !tool_calls.nil? && !tool_calls.empty?
        unless has_text || has_tools
          fail "#{name}: stream accumulated to neither content nor tool_calls (content=#{final.content.inspect})"
        end

        # The final usage-only event carries token counts in every fixture.
        out = final.output_tokens
        if out.nil?
          fail "#{name}: expected output_tokens from the stream's usage event"
        end
        out.should be > 0
        final.model_id.should_not be_nil
      end
    end
  end

  describe "streaming exact values" do
    it "stream_1: accumulates the best_language_to_learn tool call" do
      provider = build_openai_provider
      config = CrystalLLM::Configuration.new
      config.openai_api_key = "test"
      stub = CrystalLLM::Spec::StubConnection.new(provider, config)
      provider.connection = stub
      stub.stub_stream(File.read(File.join(FIXTURE_DIR, "stream_1.sse")))

      final = provider.stream_response("{}") { |_| }

      tool_calls = final.tool_calls
      if tool_calls.nil?
        fail "stream_1: expected accumulated tool_calls, got nil"
      end
      tool_calls.size.should eq(1)
      tool_calls.values.first.name.should eq("best_language_to_learn")
      # usage event: completion_tokens 150, reasoning_tokens 128
      final.output_tokens.should eq(150)
      final.thinking_tokens.should eq(128)
    end

    # REGRESSION (BUG 1): OpenAI streams tool-call `arguments` as a raw JSON String
    # split across deltas (`parse_arguments: false`). The fragments must concatenate
    # and parse ONCE — before the fix each delta parsed to {} and the args were lost.
    # (The harvested OpenAI fixtures only carry empty-arg tool calls; this drives the
    # real provider build_chunk + accumulator with the documented split-fragment shape.)
    it "reconstructs split tool-call arguments across deltas" do
      provider = build_openai_provider
      config = CrystalLLM::Configuration.new
      config.openai_api_key = "test"
      stub = CrystalLLM::Spec::StubConnection.new(provider, config)
      provider.connection = stub

      sse = <<-SSE
        data: {"model":"gpt-4o","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","type":"function","function":{"name":"weather","arguments":""}}]}}]}

        data: {"model":"gpt-4o","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"city\\": \\"Par"}}]}}]}

        data: {"model":"gpt-4o","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"is\\"}"}}]}}]}

        data: [DONE]


        SSE
      stub.stub_stream(sse)

      final = provider.stream_response("{}") { |_| }
      tool_calls = final.tool_calls.should_not be_nil
      tool_calls["call_x"].name.should eq("weather")
      tool_calls["call_x"].arguments["city"].as_s.should eq("Paris")
    end

    it "stream_3: accumulates the text deltas '1, 2, 3'" do
      provider = build_openai_provider
      config = CrystalLLM::Configuration.new
      config.openai_api_key = "test"
      stub = CrystalLLM::Spec::StubConnection.new(provider, config)
      provider.connection = stub
      stub.stub_stream(File.read(File.join(FIXTURE_DIR, "stream_3.sse")))

      final = provider.stream_response("{}") { |_| }

      message_text(final).should eq("1, 2, 3")
      # usage event: prompt 14, completion 7, total 21
      final.input_tokens.should eq(14)
      final.output_tokens.should eq(7)
    end
  end

  describe "parse_embedding_response (embedding_*.json)" do
    Dir.glob(File.join(FIXTURE_DIR, "embedding_*.json")).sort.each do |path|
      name = File.basename(path)

      it "parses #{name} into an Embedding with a non-empty vector" do
        provider = build_openai_provider
        body = read_cassette_json(path)
        # Single-string input -> flat Array(Float64) per the flatten rule.
        embedding = provider.parse_embedding_response(
          crest_response(body), "text-embedding-3-small", "ruby")

        embedding.should be_a(CrystalLLM::Embedding)
        embedding.model.should eq("text-embedding-3-small")
        embedding.input_tokens.should be > 0

        vectors = embedding.vectors
        # Single, non-array input flattens to a flat Float64 vector.
        flat = vectors.as?(Array(Float64))
        if flat.nil?
          fail "#{name}: expected a flat Array(Float64) for single-string input, got #{vectors.class}"
        end
        flat.empty?.should be_false
        # text-embedding-3-small is 1536-dim; assert real numbers, not zeros.
        flat.size.should eq(1536)
        flat.any? { |v| v != 0.0 }.should be_true
      end
    end
  end

  describe "parse_image_response (image_*.json)" do
    Dir.glob(File.join(FIXTURE_DIR, "image_*.json")).sort.each do |path|
      name = File.basename(path)

      it "parses #{name} into an Image with url or base64 data" do
        provider = build_openai_provider
        body = read_cassette_json(path)
        image = provider.parse_image_response(crest_response(body), "dall-e-3")

        image.should be_a(CrystalLLM::Image)
        image.model_id.should eq("dall-e-3")

        url = image.url
        data = image.data
        has_url = !url.nil? && !url.empty?
        has_data = !data.nil? && !data.empty?
        unless has_url || has_data
          fail "#{name}: expected a url or base64 data, got neither"
        end
      end
    end
  end

  describe "image exact values" do
    it "image_4: url-backed image with a revised_prompt" do
      provider = build_openai_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "image_4.json"))
      image = provider.parse_image_response(crest_response(body), "dall-e-3")

      url = image.url
      if url.nil?
        fail "image_4: expected a url"
      end
      url.should start_with("https://")
      image.base64?.should be_false
      rp = image.revised_prompt
      if rp.nil?
        fail "image_4: expected a revised_prompt"
      end
      rp.should contain("Siamese")
    end

    it "image_2: base64 image carries usage tokens" do
      provider = build_openai_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "image_2.json"))
      image = provider.parse_image_response(crest_response(body), "gpt-image-1")

      image.base64?.should be_true
      image.data.should_not be_nil
      image.usage["input_tokens"]?.try(&.as_i).should eq(221)
      image.usage["output_tokens"]?.try(&.as_i).should eq(272)
    end
  end

  describe "parse_moderation_response (moderation_*.json)" do
    Dir.glob(File.join(FIXTURE_DIR, "moderation_*.json")).sort.each do |path|
      name = File.basename(path)

      it "parses #{name} into a Moderation with results" do
        provider = build_openai_provider
        body = read_cassette_json(path)
        moderation = provider.parse_moderation_response(crest_response(body), "omni-moderation-latest")

        moderation.should be_a(CrystalLLM::Moderation)
        moderation.model.should eq("omni-moderation-latest")
        moderation.id.empty?.should be_false
        moderation.results.empty?.should be_false
        # Real fixtures all carry a categories map on the first result.
        moderation.categories.empty?.should be_false
        moderation.category_scores.empty?.should be_false
      end
    end
  end

  describe "moderation exact values" do
    it "moderation_1: not flagged, id present" do
      provider = build_openai_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "moderation_1.json"))
      moderation = provider.parse_moderation_response(crest_response(body), "omni-moderation-latest")

      moderation.id.should eq("modr-7927")
      moderation.flagged?.should be_false
      moderation.flagged_categories.empty?.should be_true
    end
  end

  describe "parse_transcription_response (transcription_*.json)" do
    Dir.glob(File.join(FIXTURE_DIR, "transcription_*.json")).sort.each do |path|
      name = File.basename(path)

      it "parses #{name} into a Transcription with text" do
        provider = build_openai_provider
        body = read_cassette_json(path)
        transcription = provider.parse_transcription_response(crest_response(body), "whisper-1")

        transcription.should be_a(CrystalLLM::Transcription)
        transcription.model.should eq("whisper-1")
        transcription.text.empty?.should be_false
      end
    end
  end

  describe "transcription exact values" do
    it "transcription_1: text 'Ruby' with segments + token usage" do
      provider = build_openai_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "transcription_1.json"))
      transcription = provider.parse_transcription_response(crest_response(body), "gpt-4o-transcribe")

      transcription.text.should eq("Ruby")
      segments = transcription.segments
      if segments.nil?
        fail "transcription_1: expected segments"
      end
      segments.empty?.should be_false
      # usage.input_tokens 11, output_tokens 75
      transcription.input_tokens.should eq(11)
      transcription.output_tokens.should eq(75)
    end

    it "transcription_2: duration-usage fixture (no segments)" do
      provider = build_openai_provider
      body = read_cassette_json(File.join(FIXTURE_DIR, "transcription_2.json"))
      transcription = provider.parse_transcription_response(crest_response(body), "whisper-1")

      transcription.text.should eq("Ruby")
      transcription.segments.should be_nil
    end
  end
end
