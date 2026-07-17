# ported from lib/ruby_llm/providers/bedrock/chat.rb @ ruby_llm 1.16.0
#
# The AWS Bedrock Converse API request/response surface.
#
# Divergences:
# - `completion_url`/`stream_url` (the latter in streaming.cr) read `@model.id` in
#   ruby_llm, where `@model` is stashed by render_payload. The frozen interface's
#   url hooks take no model argument, so the port keeps a `@current_model` ivar set
#   by render_payload (mirroring ruby_llm's `@model`).
# - `messages` partition into system/chat is ported. render_message_content handles
#   the text / Content::Raw / tool_call paths and now also emits rich attachment blocks
#   (image / document / text) via the Bedrock::Media module — see
#   `render_attachment_blocks`. System messages stay text-only (Bedrock system blocks).
# - `render_payload` returns `Hash(String, JSON::Any)`. Symbol-keyed Ruby payloads
#   become String-keyed JSON::Any (the Bedrock wire uses camelCase keys verbatim).
# - thinking text/signature extraction onto Message is deferred (Message#thinking
#   deferred); reasoning_tokens ARE wired into Tokens.
# - `tool_prefs` is threaded: `render_tool_config(tools, tool_prefs)` emits
#   `toolConfig.toolChoice` from `tool_prefs["choice"]` via `render_tool_choice`
#   (`{auto:{}}` / nil / `{any:{}}` / `{tool:{name}}`). Bedrock Converse has no
#   parallel-call control, so `calls` is ignored (ruby_llm parity).
require "json"
require "../bedrock"

module CrystalLLM
  module Providers
    class Bedrock < Provider
      # Set by render_payload (mirrors ruby_llm's `@model` instance state); read by
      # completion_url / stream_url which take no model arg in the frozen interface.
      @current_model : Model::Info? = nil
      # ruby_llm's `@used_document_names` (document-name de-dup across a payload);
      # reset per render_payload and threaded into Bedrock::Media.render_attachment.
      @used_document_names = {} of String => Int32

      def completion_url : String
        "/model/#{@current_model.try(&.id)}/converse"
      end

      def render_payload(messages : Array(Message), tools : Hash(String, Tool),
                         temperature : Float64?, model : Model::Info,
                         stream : Bool = false, schema : JSON::Any? = nil,
                         thinking : Thinking::Config? = nil,
                         tool_prefs : Hash(String, String?)? = nil) : Hash(String, JSON::Any)
        @current_model = model
        @used_document_names = {} of String => Int32

        system_messages, chat_messages = partition_system(messages)

        payload = {
          "messages" => JSON::Any.new(render_messages(chat_messages)),
        } of String => JSON::Any

        system_blocks = render_system(system_messages)
        payload["system"] = JSON::Any.new(system_blocks) unless system_blocks.empty?

        payload["inferenceConfig"] = JSON::Any.new(render_inference_config(temperature))

        if tool_config = render_tool_config(tools, tool_prefs)
          payload["toolConfig"] = JSON::Any.new(tool_config)
          # NOTE: ruby_llm sets a top-level `payload[:tools]` mirror here, but it exists
          # ONLY so `api_payload` can delete it before SigV4 signing (a spec-inspection
          # affordance never sent on the wire). The Crystal port collapsed that delete
          # step, so mirroring the key here would LEAK a redundant top-level `tools`
          # onto every Converse request (sync + stream). Real tools live under
          # `toolConfig.tools` (render_tool_config) — do NOT re-add the mirror.
        end

        if additional_fields = render_additional_model_request_fields(thinking, model)
          payload["additionalModelRequestFields"] = JSON::Any.new(additional_fields)
        end

        if output_config = build_output_config(schema)
          payload["outputConfig"] = JSON::Any.new(output_config)
        end

        payload
      end

      def parse_completion_response(response : Crest::Response) : Message
        body = response.body
        raise Error.new(response, "Empty response from Bedrock") if body.empty?

        data = JSON.parse(body)

        content_blocks = data.dig?("output", "message", "content").try(&.as_a?) || [] of JSON::Any
        usage = data["usage"]?.try(&.as_h?) || {} of String => JSON::Any

        Message.new(
          role: Role::Assistant,
          content: parse_text_content(content_blocks),
          tool_calls: parse_tool_calls_from_blocks(content_blocks),
          input_tokens: input_tokens(usage),
          output_tokens: int_at(usage["outputTokens"]?),
          cached_tokens: int_at(usage["cacheReadInputTokens"]?),
          cache_creation_tokens: int_at(usage["cacheWriteInputTokens"]?),
          thinking_tokens: int_at(usage["reasoningTokens"]?),
          model_id: data["modelId"]?.try(&.as_s?),
          raw: data
        )
      end

      # ruby_llm: input_tokens - cacheRead - cacheWrite, floored at 0.
      def input_tokens(usage : Hash(String, JSON::Any)) : Int32?
        input = int_at(usage["inputTokens"]?)
        return nil unless input

        cache_read = int_at(usage["cacheReadInputTokens"]?) || 0
        cache_write = int_at(usage["cacheWriteInputTokens"]?) || 0
        {input - cache_read - cache_write, 0}.max
      end

      # ---- Message rendering ----

      private def partition_system(messages : Array(Message)) : Tuple(Array(Message), Array(Message))
        system = [] of Message
        chat = [] of Message
        messages.each do |msg|
          msg.role.system? ? (system << msg) : (chat << msg)
        end
        {system, chat}
      end

      def render_messages(messages : Array(Message)) : Array(JSON::Any)
        rendered = [] of JSON::Any
        tool_result_blocks = [] of JSON::Any

        messages.each do |msg|
          if msg.tool_result?
            tool_result_blocks << render_tool_result_block(msg)
            next
          end

          unless tool_result_blocks.empty?
            rendered << user_message(tool_result_blocks)
            tool_result_blocks = [] of JSON::Any
          end

          if message = render_non_tool_message(msg)
            rendered << message
          end
        end

        rendered << user_message(tool_result_blocks) unless tool_result_blocks.empty?
        rendered
      end

      private def user_message(blocks : Array(JSON::Any)) : JSON::Any
        JSON::Any.new({
          "role"    => JSON::Any.new("user"),
          "content" => JSON::Any.new(blocks),
        } of String => JSON::Any)
      end

      private def render_non_tool_message(msg : Message) : JSON::Any?
        content = render_message_content(msg)
        return nil if content.empty?

        JSON::Any.new({
          "role"    => JSON::Any.new(render_role(msg.role)),
          "content" => JSON::Any.new(content),
        } of String => JSON::Any)
      end

      # Renders a message's content blocks. Rich attachment (image/document) rendering
      # is DEFERRED (attachment-provider work — see bedrock.cr header). This ports the
      # text + Content::Raw + tool_call paths chat needs.
      private def render_message_content(msg : Message) : Array(JSON::Any)
        content = msg.content
        if content.is_a?(Content::Raw)
          blocks = render_raw_content(content)
          return blocks if msg.role.assistant?
          return sanitize_non_assistant_raw_blocks(blocks)
        end

        blocks = [] of JSON::Any
        text_blocks = render_text_content(content)
        blocks.concat(text_blocks)
        blocks.concat(render_attachment_blocks(content))

        if msg.tool_call?
          if calls = msg.tool_calls
            calls.each_value do |tool_call|
              blocks << JSON::Any.new({
                "toolUse" => JSON::Any.new({
                  "toolUseId" => JSON::Any.new(tool_call.id),
                  "name"      => JSON::Any.new(tool_call.name),
                  "input"     => JSON::Any.new(tool_call.arguments),
                } of String => JSON::Any),
              } of String => JSON::Any)
            end
          end
        end

        blocks
      end

      # The text/Hash/Array slice of ruby_llm's Media.render_content (rich attachments
      # deferred). nil/empty -> [], a String -> one text block.
      private def render_text_content(content : String | Content | Content::Raw | Nil) : Array(JSON::Any)
        case content
        when Nil
          [] of JSON::Any
        when String
          content.empty? ? [] of JSON::Any : [text_block(content)]
        when Content::Raw
          # Raw is handled by render_message_content before this is reached; emit the
          # raw blocks if ever called directly.
          render_raw_content(content)
        else # Content
          blocks = [] of JSON::Any
          if t = content.text
            blocks << text_block(t) unless t.empty?
          end
          blocks
        end
      end

      private def text_block(text : String) : JSON::Any
        JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any)
      end

      # Renders a Content's attachments into Converse content blocks (image / document /
      # text). Mirrors ruby_llm's render_content_object attachment loop, threading the
      # payload-scoped `@used_document_names` for document-name de-dup. Non-Content
      # content carries no attachments and yields no blocks.
      private def render_attachment_blocks(content : String | Content | Content::Raw | Nil) : Array(JSON::Any)
        return [] of JSON::Any unless content.is_a?(Content)

        content.attachments.map do |attachment|
          Media.render_attachment(attachment, @used_document_names)
        end
      end

      private def render_raw_content(content : Content::Raw) : Array(JSON::Any)
        value = content.value
        value.as_a? || [value]
      end

      private def sanitize_non_assistant_raw_blocks(blocks : Array(JSON::Any)) : Array(JSON::Any)
        blocks.select do |block_any|
          hash = block_any.as_h?
          next false unless hash
          !hash.has_key?("reasoningContent")
        end
      end

      private def render_tool_result_block(msg : Message) : JSON::Any
        JSON::Any.new({
          "toolResult" => JSON::Any.new({
            "toolUseId" => JSON::Any.new(msg.tool_call_id),
            "content"   => JSON::Any.new(render_tool_result_content(msg.content)),
          } of String => JSON::Any),
        } of String => JSON::Any)
      end

      private def render_tool_result_content(content : String | Content | Content::Raw | Nil) : Array(JSON::Any)
        case content
        when Content::Raw
          render_raw_tool_result_content(content.value)
        when Content
          render_content_tool_result_content(content)
        when String
          [text_tool_result_block(content)]
        else
          [text_tool_result_block(nil)]
        end
      end

      private def render_content_tool_result_content(content : Content) : Array(JSON::Any)
        blocks = [] of JSON::Any
        if (t = content.text) && !t.empty?
          blocks << text_tool_result_block(t)
        end
        blocks.empty? ? [text_tool_result_block(nil)] : blocks
      end

      private def text_tool_result_block(text : String?) : JSON::Any
        value = (text.nil? || text.empty?) ? "(no output)" : text
        JSON::Any.new({"text" => JSON::Any.new(value)} of String => JSON::Any)
      end

      private def render_raw_tool_result_content(raw_value : JSON::Any) : Array(JSON::Any)
        blocks = raw_value.as_a? || [raw_value]
        normalized = blocks.compact_map { |block| normalize_tool_result_block(block) }
        normalized.empty? ? [text_tool_result_block(raw_value.to_s)] : normalized
      end

      private def normalize_tool_result_block(block : JSON::Any) : JSON::Any?
        hash = block.as_h?
        return nil unless hash
        tool_result_content_block?(hash) ? block : nil
      end

      private def tool_result_content_block?(block : Hash(String, JSON::Any)) : Bool
        %w[text json document image].any? { |key| block.has_key?(key) }
      end

      private def render_role(role : Role) : String
        role.assistant? ? "assistant" : "user"
      end

      def render_system(messages : Array(Message)) : Array(JSON::Any)
        blocks = [] of JSON::Any
        messages.each { |msg| blocks.concat(render_text_content(msg.content)) }
        blocks
      end

      private def render_inference_config(temperature : Float64?) : Hash(String, JSON::Any)
        config = {} of String => JSON::Any
        config["temperature"] = JSON::Any.new(temperature) unless temperature.nil?
        config
      end

      # ---- Tools ----

      # Renders `toolConfig`: the tools list plus an optional `toolChoice` derived
      # from `tool_prefs["choice"]` (via render_tool_choice).
      def render_tool_config(tools : Hash(String, Tool),
                             tool_prefs : Hash(String, String?)? = nil) : Hash(String, JSON::Any)?
        return nil if tools.empty?

        config = {
          "tools" => JSON::Any.new(tools.map { |_, tool| render_tool(tool) }),
        } of String => JSON::Any

        choice = tool_prefs.try(&.["choice"]?)
        unless choice.nil?
          if tool_choice = render_tool_choice(choice)
            config["toolChoice"] = JSON::Any.new(tool_choice)
          end
        end

        config
      end

      def render_tool_choice(choice : String) : Hash(String, JSON::Any)?
        case choice
        when "auto"
          {"auto" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any
        when "none"
          nil
        when "required"
          {"any" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any
        else
          {"tool" => JSON::Any.new({"name" => JSON::Any.new(choice)} of String => JSON::Any)} of String => JSON::Any
        end
      end

      def render_tool(tool : Tool) : JSON::Any
        input_schema = tool.params_schema
        input_schema = default_input_schema if input_schema.empty?

        tool_spec = {
          "toolSpec" => JSON::Any.new({
            "name"        => JSON::Any.new(tool.name),
            "description" => JSON::Any.new(tool.description),
            "inputSchema" => JSON::Any.new({
              "json" => JSON::Any.new(input_schema),
            } of String => JSON::Any),
          } of String => JSON::Any),
        } of String => JSON::Any

        return JSON::Any.new(tool_spec) if tool.provider_params.empty?

        JSON::Any.new(Utils.deep_merge(tool_spec, tool.provider_params))
      end

      private def default_input_schema : Hash(String, JSON::Any)
        {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({} of String => JSON::Any),
          "required"   => JSON::Any.new([] of JSON::Any),
        } of String => JSON::Any
      end

      # ---- Reasoning / schema fields ----

      def render_additional_model_request_fields(thinking : Thinking::Config?,
                                                 model : Model::Info) : Hash(String, JSON::Any)?
        fields = render_reasoning_fields(thinking, model)
        return nil if fields.nil? || fields.empty?
        fields
      end

      private def render_reasoning_fields(thinking : Thinking::Config?,
                                          model : Model::Info) : Hash(String, JSON::Any)?
        return nil unless thinking && thinking.enabled?

        if effort_config = effort_reasoning_config(thinking, model)
          return effort_config
        end

        budget_reasoning_config(thinking)
      end

      private def effort_reasoning_config(thinking : Thinking::Config,
                                          model : Model::Info) : Hash(String, JSON::Any)?
        effort = thinking.effort
        return nil if effort.nil? || effort.empty? || effort == "none"

        if Capabilities.reasoning_embedded?(model)
          {
            "reasoning_config" => JSON::Any.new({
              "type"             => JSON::Any.new("enabled"),
              "reasoning_effort" => JSON::Any.new(effort),
            } of String => JSON::Any),
          } of String => JSON::Any
        else
          {"reasoning_effort" => JSON::Any.new(effort)} of String => JSON::Any
        end
      end

      private def budget_reasoning_config(thinking : Thinking::Config) : Hash(String, JSON::Any)?
        budget = thinking.budget
        return nil unless budget

        {
          "reasoning_config" => JSON::Any.new({
            "type"          => JSON::Any.new("enabled"),
            "budget_tokens" => JSON::Any.new(budget.to_i64),
          } of String => JSON::Any),
        } of String => JSON::Any
      end

      def build_output_config(schema : JSON::Any?) : Hash(String, JSON::Any)?
        return nil unless schema

        cleaned = schema_inner(schema)
        return nil unless cleaned
        cleaned.delete("strict")

        {
          "textFormat" => JSON::Any.new({
            "type"      => JSON::Any.new("json_schema"),
            "structure" => JSON::Any.new({
              "jsonSchema" => JSON::Any.new({
                "schema" => JSON::Any.new(JSON::Any.new(cleaned).to_json),
                "name"   => schema_name(schema),
              } of String => JSON::Any),
            } of String => JSON::Any),
          } of String => JSON::Any),
        } of String => JSON::Any
      end

      # The schema envelope from the chat layer is `{name, schema, strict}`; the inner
      # `schema` is the json-schema body Bedrock embeds.
      private def schema_inner(schema : JSON::Any) : Hash(String, JSON::Any)?
        hash = schema.as_h?
        return nil unless hash
        inner = hash["schema"]?.try(&.as_h?)
        inner.try(&.dup)
      end

      private def schema_name(schema : JSON::Any) : JSON::Any
        schema.as_h?.try { |hash| hash["name"]? } || JSON::Any.new(nil)
      end

      # ---- Response parsing ----

      def parse_text_content(content_blocks : Array(JSON::Any)) : String?
        text = String.build do |io|
          content_blocks.each do |block_any|
            block = block_any.as_h? || next
            if t = block["text"]?.try(&.as_s?)
              io << t
            end
          end
        end
        text.empty? ? nil : text
      end

      def parse_tool_calls_from_blocks(content_blocks : Array(JSON::Any)) : Hash(String, ToolCall)?
        tool_calls = {} of String => ToolCall

        content_blocks.each do |block_any|
          block = block_any.as_h? || next
          tool_use = block["toolUse"]?.try(&.as_h?) || next

          id = tool_use["toolUseId"]?.try(&.as_s?) || ""
          name = tool_use["name"]?.try(&.as_s?) || ""
          arguments = tool_use["input"]?.try(&.as_h?) || {} of String => JSON::Any

          tool_calls[id] = ToolCall.new(id: id, name: name, arguments: arguments)
        end

        tool_calls.empty? ? nil : tool_calls
      end

      # Coerce a JSON::Any numeric to Int32 (Bedrock token counts).
      private def int_at(value : JSON::Any?) : Int32?
        return nil if value.nil?
        case raw = value.raw
        when Int64   then raw.to_i32
        when Int32   then raw
        when Float64 then raw.to_i32
        else              nil
        end
      end
    end
  end
end
