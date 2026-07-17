# ported from lib/ruby_llm/message.rb @ ruby_llm 1.15.0
require "json"
require "./content"
require "./tokens"
require "./tool_call"
require "./cost"
require "./models"
require "./error"
require "./thinking"

module CrystalLLM
  # The role of a message. ruby_llm uses symbols (:system/:user/:assistant/:tool);
  # an enum is the Crystal idiom (design R5) and handles runtime strings from APIs.
  enum Role
    System
    User
    Assistant
    Tool
  end

  # A single message in a chat conversation.
  class Message
    getter role : Role
    getter model_id : String?
    getter tool_calls : Hash(String, ToolCall)?
    getter tool_call_id : String?
    getter tokens : Tokens?
    getter raw : JSON::Any?

    # Inbound extended-reasoning output (text + signature). Providers that surface
    # reasoning (Anthropic thinking blocks, Gemini thoughts, OpenRouter/Mistral/
    # OpenAI reasoning) attach it here so the round-trip survives; nil otherwise.
    getter thinking : Thinking?

    # `cost`/`model_info` are implemented below (model/info and cost are ported):
    # `model_info` resolves `model_id` via the registry, `cost` builds a `Cost`.
    def initialize(role : Role | Symbol | String, content : String | Content | Content::Raw | Nil = nil,
                   tool_calls : Hash(String, ToolCall)? = nil, tool_call_id : String? = nil,
                   model_id : String? = nil, tokens : Tokens? = nil, raw : JSON::Any? = nil,
                   thinking : Thinking? = nil,
                   input_tokens : Int32? = nil, output_tokens : Int32? = nil,
                   cached_tokens : Int32? = nil, cache_creation_tokens : Int32? = nil,
                   thinking_tokens : Int32? = nil, reasoning_tokens : Int32? = nil)
      @role = normalize_role(role)
      @tool_calls = tool_calls
      @content = normalize_content(content, @role, tool_calls)
      @model_id = model_id
      @tool_call_id = tool_call_id
      @tokens = tokens || Tokens.build(
        input: input_tokens, output: output_tokens, cached: cached_tokens,
        cache_creation: cache_creation_tokens, thinking: thinking_tokens, reasoning: reasoning_tokens
      )
      @raw = raw
      @thinking = thinking
    end

    # Unwraps a simple text Content back to the bare String (matches ruby_llm). A
    # `Content::Raw` (provider-native block payload) is NOT a `Content`, so it falls
    # through the `is_a?(Content)` guard and is returned as-is.
    def content : String | Content | Content::Raw | Nil
      c = @content
      if c.is_a?(Content) && (text = c.text) && c.attachments.empty?
        text
      else
        c
      end
    end

    def content=(value : String | Content | Content::Raw | Nil)
      @content = value
    end

    def tool_call? : Bool
      (tc = @tool_calls) ? !tc.empty? : false
    end

    def tool_result? : Bool
      (id = @tool_call_id) ? !id.empty? : false
    end

    def tool_results : String | Content | Content::Raw | Nil
      content if tool_result?
    end

    def input_tokens : Int32?
      @tokens.try(&.input)
    end

    def output_tokens : Int32?
      @tokens.try(&.output)
    end

    def cached_tokens : Int32?
      @tokens.try(&.cached)
    end

    def cache_creation_tokens : Int32?
      @tokens.try(&.cache_creation)
    end

    def cache_read_tokens : Int32?
      @tokens.try(&.cache_read)
    end

    def cache_write_tokens : Int32?
      @tokens.try(&.cache_write)
    end

    def thinking_tokens : Int32?
      @tokens.try(&.thinking)
    end

    def reasoning_tokens : Int32?
      @tokens.try(&.thinking)
    end

    # The cost of this message's token usage. Mirrors ruby_llm's
    # `cost(model: nil) = Cost.new(tokens:, model: model || model_info)`.
    def cost(model : Model::Info? = nil) : Cost
      Cost.new(tokens: @tokens, model: model || model_info)
    end

    # Resolves the `Model::Info` for `model_id` via the registry, memoized. Mirrors
    # ruby_llm's `model_info` (returns nil when `model_id` is nil or unknown).
    def model_info : Model::Info?
      id = @model_id
      return nil unless id
      @model_info ||= Models.find(id)
    rescue ModelNotFoundError
      nil
    end

    @model_info : Model::Info?

    # Mirrors ruby_llm's `Message#to_h`: the persistence/serialization contract.
    # ruby_llm returns a `{role:, content:, model_id:, tool_calls:, tool_call_id:,
    # thinking:, thinking_signature:}.merge(tokens.to_h).compact` (compact = drop
    # nils). Crystal's strong typing means the values are a union, so this returns
    # `Hash(Symbol, ...)` rather than a single concrete value type.
    #
    # DIVERGENCE: the full structural serialization of `content` (Content/attachments)
    # and `tool_calls` (ToolCall round-trip) is the crystal-llm-marten persistence
    # concern (PORTING.md). Here `content` is unwrapped via `#content` (String/Content),
    # `tool_calls` is passed through, and `thinking`/`thinking_signature` are wired —
    # the thinking round-trip is the point of this method landing now.
    def to_h : Hash(Symbol, Role | String | Content | Content::Raw | Hash(String, ToolCall) | Int32 | Nil)
      result = {} of Symbol => Role | String | Content | Content::Raw | Hash(String, ToolCall) | Int32 | Nil
      result[:role] = @role
      result[:content] = content
      result[:model_id] = @model_id unless @model_id.nil?
      result[:tool_calls] = @tool_calls unless @tool_calls.nil?
      result[:tool_call_id] = @tool_call_id unless @tool_call_id.nil?
      if t = @thinking
        result[:thinking] = t.text unless t.text.nil?
        result[:thinking_signature] = t.signature unless t.signature.nil?
      end
      @tokens.try(&.to_h).try(&.each { |k, v| result[k] = v })
      result
    end

    private def normalize_role(role : Role | Symbol | String) : Role
      case role
      when Role
        role
      when Symbol
        case role
        when :system    then Role::System
        when :user      then Role::User
        when :assistant then Role::Assistant
        when :tool      then Role::Tool
        else                 raise InvalidRoleError.new("Expected role to be one of: system, user, assistant, tool")
        end
      else
        Role.parse?(role.to_s) || raise InvalidRoleError.new("Expected role to be one of: system, user, assistant, tool")
      end
    end

    private def normalize_content(content : String | Content | Content::Raw | Nil, role : Role,
                                  tool_calls : Hash(String, ToolCall)?) : Content | Content::Raw | String | Nil
      return "" if role.assistant? && content.nil? && tool_calls && !tool_calls.empty?

      case content
      when String then Content.new(content)
      else             content # Content / Content::Raw pass through unchanged
      end
    end
  end
end
