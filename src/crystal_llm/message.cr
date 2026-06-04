# ported from lib/ruby_llm/message.rb @ ruby_llm 1.15.0
require "json"
require "./content"
require "./tokens"
require "./tool_call"

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

    # NOTE: `cost`/`model_info` and `thinking` are deferred until model/info, cost,
    # and thinking are ported (tracked in PORTING.md).
    def initialize(role : Role | Symbol | String, content : String | Content | Nil = nil,
                   tool_calls : Hash(String, ToolCall)? = nil, tool_call_id : String? = nil,
                   model_id : String? = nil, tokens : Tokens? = nil, raw : JSON::Any? = nil,
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
    end

    # Unwraps a simple text Content back to the bare String (matches ruby_llm).
    def content : String | Content | Nil
      c = @content
      if c.is_a?(Content) && (text = c.text) && c.attachments.empty?
        text
      else
        c
      end
    end

    def content=(value : String | Content | Nil)
      @content = value
    end

    def tool_call? : Bool
      (tc = @tool_calls) ? !tc.empty? : false
    end

    def tool_result? : Bool
      (id = @tool_call_id) ? !id.empty? : false
    end

    def tool_results : String | Content | Nil
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

    # NOTE: `to_h` (the persistence contract) is deferred to crystal-llm-marten,
    # along with `cost`/`model_info`/`thinking`. See PORTING.md.

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

    private def normalize_content(content : String | Content | Nil, role : Role,
                                  tool_calls : Hash(String, ToolCall)?) : Content | String | Nil
      return "" if role.assistant? && content.nil? && tool_calls && !tool_calls.empty?

      case content
      when String then Content.new(content)
      else             content
      end
    end
  end
end
