# Offline integration-flow specs: exercise the FULL chat path
#   Chat#ask -> Provider#complete -> Connection -> parse_completion_response -> Message
# against a REAL provider (OpenAI, plus one Anthropic flow) with NO network. HTTP is
# stubbed by injecting a `CrystalLLM::Spec::StubConnection` via the `Provider#connection=`
# test affordance, so render_payload / parse_completion_response / the streaming
# accumulator / the tool-call loop all run for real.
require "../spec_helper"
require "../support/stub_connection"
require "../../src/crystal_llm"

private CONFIGURED = begin
  CrystalLLM.config.openai_api_key = "test"
  CrystalLLM.config.anthropic_api_key = "test"
  true
end

# Builds a Chat on a real provider but swaps in a StubConnection on the provider
# instance the Chat already resolved. Returns {chat, stub} so the test can both
# queue canned responses and assert on the recorded wire requests.
private def stubbed_chat(model : String, provider : String) : Tuple(CrystalLLM::Chat, CrystalLLM::Spec::StubConnection)
  chat = CrystalLLM::Chat.new(model: model, provider: provider, assume_model_exists: true)
  prov = chat.@provider
  stub = CrystalLLM::Spec::StubConnection.new(prov, CrystalLLM.config)
  prov.connection = stub
  {chat, stub}
end

# ---- Fixture builders (provider wire shapes) -------------------------------

private def openai_text_response(content : String) : String
  {
    "id"      => "chatcmpl-1",
    "model"   => "gpt-4o",
    "choices" => [{
      "index"         => 0,
      "message"       => {"role" => "assistant", "content" => content},
      "finish_reason" => "stop",
    }],
    "usage" => {"prompt_tokens" => 11, "completion_tokens" => 7, "total_tokens" => 18},
  }.to_json
end

private def openai_tool_call_response(call_id : String, name : String, args : String) : String
  {
    "id"      => "chatcmpl-2",
    "model"   => "gpt-4o",
    "choices" => [{
      "index"   => 0,
      "message" => {
        "role"       => "assistant",
        "content"    => nil,
        "tool_calls" => [{
          "id"       => call_id,
          "type"     => "function",
          "function" => {"name" => name, "arguments" => args},
        }],
      },
      "finish_reason" => "tool_calls",
    }],
    "usage" => {"prompt_tokens" => 20, "completion_tokens" => 5, "total_tokens" => 25},
  }.to_json
end

private def anthropic_text_response(content : String) : String
  {
    "id"      => "msg_1",
    "type"    => "message",
    "role"    => "assistant",
    "model"   => "claude-sonnet-4",
    "content" => [{"type" => "text", "text" => content}],
    "usage"   => {"input_tokens" => 9, "output_tokens" => 4},
  }.to_json
end

# A tool that records whether it ran, to assert real execution in the loop.
class FlowEchoTool < CrystalLLM::Tool
  class_property ran : Bool = false
  class_property last_word : String? = nil

  description "Echoes the supplied word"
  param word : String, "the word to echo", required: true # ameba:disable Lint/UselessAssign

  def dispatch(args : Hash(String, JSON::Any)) : CrystalLLM::ToolResult
    FlowEchoTool.ran = true
    word = args["word"].as_s
    FlowEchoTool.last_word = word
    "echo: #{word}"
  end
end

describe "offline chat flow (integration)" do
  it "is configured" { CONFIGURED.should be_true }

  describe "(a) OpenAI text completion" do
    it "ask returns an assistant Message with the fixture content and tokens" do
      chat, stub = stubbed_chat("gpt-4o", "openai")
      stub.stub_response(openai_text_response("hello from the stub"))

      response = chat.ask("hi").as(CrystalLLM::Message)

      response.role.should eq(CrystalLLM::Role::Assistant)
      response.content.should eq("hello from the stub")
      response.output_tokens.should eq(7)
      # input = prompt(11) - cache_read(0) - cache_write(0)
      response.input_tokens.should eq(11)

      # the full path actually POSTed the rendered payload to the completions URL
      stub.posts.size.should eq(1)
      url, payload = stub.posts.first
      url.should eq("chat/completions")
      sent = JSON.parse(payload)
      sent["model"].as_s.should eq("gpt-4o")
      sent.dig("messages", 0, "role").as_s.should eq("user")
    end
  end

  describe "(b) OpenAI tool-call flow" do
    it "executes a registered tool then re-completes for the final answer" do
      FlowEchoTool.ran = false
      FlowEchoTool.last_word = nil

      chat, stub = stubbed_chat("gpt-4o", "openai")
      chat.with_tool(FlowEchoTool.new)

      # First completion asks to call the tool; second returns the final answer.
      stub.stub_response(openai_tool_call_response("call_1", "flow_echo", %({"word":"pong"})))
      stub.stub_response(openai_text_response("the tool said pong"))

      response = chat.ask("echo pong please").as(CrystalLLM::Message)

      FlowEchoTool.ran.should be_true
      FlowEchoTool.last_word.should eq("pong")
      response.content.should eq("the tool said pong")

      # two completions were issued (tool call + follow-up)
      stub.posts.size.should eq(2)

      # a tool-role result message was threaded back into the conversation
      tool_msg = chat.messages.find(&.role.tool?)
      if tool_msg.nil?
        fail "expected a tool-role message in the conversation"
      else
        tool_msg.content.should eq("echo: pong")
        tool_msg.tool_call_id.should eq("call_1")
      end

      # the SECOND request carried the tool result back to the model
      _first_url, second_payload = stub.posts[1]
      JSON.parse(second_payload)["messages"].as_a.size.should be >= 3
    end
  end

  describe "(c) OpenAI streaming" do
    it "accumulates the streamed Message and the block observes each chunk" do
      chat, stub = stubbed_chat("gpt-4o", "openai")
      events = [
        %({"choices":[{"delta":{"role":"assistant","content":"Hel"}}],"model":"gpt-4o"}),
        %({"choices":[{"delta":{"content":"lo!"}}],"model":"gpt-4o"}),
        %({"choices":[{"delta":{}}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5},"model":"gpt-4o"}),
        "[DONE]",
      ]
      sse = events.map { |e| "data: #{e}\n\n" }.join
      stub.stub_stream(sse)

      observed = [] of String
      final = chat.ask("stream please") do |chunk|
        c = chunk.content
        observed << c if c.is_a?(String)
      end.as(CrystalLLM::Message)

      observed.should eq(["Hel", "lo!"])
      final.content.should eq("Hello!")
      final.output_tokens.should eq(2)
      stub.stream_posts.size.should eq(1)
      # the streaming payload set stream:true
      JSON.parse(stub.stream_posts.first[1])["stream"].as_bool.should be_true
    end
  end

  describe "(d) OpenAI structured output via with_schema (raw JSON-schema Hash)" do
    it "round-trips the schema into response_format and returns the JSON content" do
      chat, stub = stubbed_chat("gpt-4o", "openai")

      raw_schema = {
        "name"   => JSON::Any.new("person"),
        "schema" => JSON::Any.new({
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "name" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
          } of String => JSON::Any),
          "required" => JSON::Any.new([JSON::Any.new("name")]),
        } of String => JSON::Any),
      } of String => JSON::Any
      chat.with_schema(raw_schema)

      stub.stub_response(openai_text_response(%({"name":"Ada"})))

      response = chat.ask("who?").as(CrystalLLM::Message)

      # the schema envelope reached the wire as a json_schema response_format
      sent = JSON.parse(stub.posts.first[1])
      sent.dig("response_format", "type").as_s.should eq("json_schema")
      sent.dig("response_format", "json_schema", "name").as_s.should eq("person")
      sent.dig("response_format", "json_schema", "schema", "type").as_s.should eq("object")

      # content is the JSON string; it parses (normalize_schema_response kept it valid)
      content = response.content
      content.should be_a(String)
      JSON.parse(content.as(String))["name"].as_s.should eq("Ada")
    end
  end

  # #4: Chat#with_params deep-merges caller-supplied provider options INTO the
  # rendered outgoing payload (via Utils.deep_merge in the completion pipeline).
  describe "(e) with_params deep-merges provider options into the payload" do
    it "merges a top-level response_format json_object into the request" do
      chat, stub = stubbed_chat("gpt-4o", "openai")
      chat.with_params({
        "response_format" => JSON::Any.new({"type" => JSON::Any.new("json_object")} of String => JSON::Any),
      } of String => JSON::Any)

      stub.stub_response(openai_text_response(%({"ok":true})))

      chat.ask("give me json")

      sent = JSON.parse(stub.posts.first[1])
      # the caller's params reached the wire merged over the rendered payload
      sent.dig("response_format", "type").as_s.should eq("json_object")
      # the base payload keys are still present (merge, not replace)
      sent["model"].as_s.should eq("gpt-4o")
      sent["messages"].as_a.size.should be >= 1
    end

    it "deep-merges nested params: nesting is preserved and the caller value wins" do
      chat, stub = stubbed_chat("gpt-4o", "openai")

      # The schema makes the provider render `response_format` as a NESTED object:
      #   { "type" => "json_schema", "json_schema" => { ... } }
      raw_schema = {
        "name"   => JSON::Any.new("person"),
        "schema" => JSON::Any.new({"type" => JSON::Any.new("object")} of String => JSON::Any),
      } of String => JSON::Any
      chat.with_schema(raw_schema)

      # The caller overrides ONE nested leaf (`type`) and adds a sibling (`extra`).
      # deep_merge must: keep the payload's `json_schema` sub-object, override
      # `type` with the caller value, and add `extra`.
      chat.with_params({
        "response_format" => JSON::Any.new({
          "type"  => JSON::Any.new("json_object"),
          "extra" => JSON::Any.new("from_caller"),
        } of String => JSON::Any),
      } of String => JSON::Any)

      stub.stub_response(openai_text_response(%({"name":"Ada"})))

      chat.ask("who?")

      sent = JSON.parse(stub.posts.first[1])
      rf = sent["response_format"]
      # caller value wins on the overlapping leaf
      rf["type"].as_s.should eq("json_object")
      # the caller-added sibling is present
      rf["extra"].as_s.should eq("from_caller")
      # the payload's nested sub-object survived the merge (deep, not shallow)
      rf["json_schema"].as_h["name"].as_s.should eq("person")
    end
  end

  describe "Anthropic text completion (multi-format wiring)" do
    it "ask returns an assistant Message from the Anthropic Messages-API shape" do
      chat, stub = stubbed_chat("claude-sonnet-4", "anthropic")
      stub.stub_response(anthropic_text_response("bonjour"))

      response = chat.ask("salut").as(CrystalLLM::Message)

      response.role.should eq(CrystalLLM::Role::Assistant)
      response.content.should eq("bonjour")
      response.input_tokens.should eq(9)
      response.output_tokens.should eq(4)

      # Anthropic's own endpoint + payload shape (max_tokens, content-block messages)
      url, payload = stub.posts.first
      url.should eq("v1/messages")
      sent = JSON.parse(payload)
      sent["max_tokens"]?.should_not be_nil
      sent.dig("messages", 0, "role").as_s.should eq("user")
    end
  end
end
