# ported from lib/ruby_llm/provider.rb @ ruby_llm 1.15.0 (the completion pipeline half)
#
# Reopens CrystalLLM::Provider to add the chat-completion request pipeline
# (`complete`/`sync_response`) and the provider hooks the pipeline dispatches to
# (`completion_url`, `render_payload`, `parse_completion_response`, `format_messages`,
# `models_url`, `parse_list_models_response`). These live in their own file (rather
# than provider.cr) because their signatures only firm up alongside `chat` + the
# first concrete provider (OpenAI) — see provider.cr's header note and PORTING.md.
#
# Divergences from ruby_llm's provider.rb#complete:
# - Ruby's single `complete(..., &)` uses `block_given?` to branch sync vs stream.
#   Crystal has no `block_given?`, so the port is two overloads: a sync `complete`
#   returning `Message`, and a streaming overload taking `&block : Chunk ->`. The
#   streaming overload passes `stream: true` to `render_payload`; the sync one
#   passes `stream: false`.
# - `tool_prefs:` (tool_choice / parallel_tool_calls preferences) IS threaded:
#   `complete` accepts `tool_prefs : Hash(String, String?)?` (Chat's `@tool_prefs`
#   shape — `{"choice" => ..., "calls" => ...}`) and forwards it to `render_payload`.
#   Each provider emits the wire-specific tool_choice/parallel control. `nil` (the
#   default) means "no preference" and providers omit the fields entirely.
# - `maybe_normalize_temperature` is a provider hook (OpenAI overrides it); the base
#   returns the temperature unchanged, matching ruby_llm.
# - `sync_response`/`stream_response` take no explicit `connection` argument (ruby_llm
#   threads `@connection` through). The port's `Connection` is reached via the
#   provider's lazy `connection` accessor / the `Streaming` mixin's `@connection`.
require "json"
require "./provider"
require "./message"
require "./chunk"
require "./tool"
require "./model/info"
require "./thinking"
require "./utils"

module CrystalLLM
  class Provider
    # The chat-completion request pipeline (sync). Renders the provider payload,
    # deep-merges caller `params` over it, POSTs, and parses the response into a
    # Message. Mirrors ruby_llm's `Provider#complete` (non-block branch).
    def complete(messages : Array(Message), tools : Hash(String, Tool),
                 temperature : Float64?, model : Model::Info,
                 params : Hash(String, JSON::Any) = {} of String => JSON::Any,
                 headers : Hash(String, String) = {} of String => String,
                 schema : JSON::Any? = nil,
                 thinking : Thinking::Config? = nil,
                 tool_prefs : Hash(String, String?)? = nil) : Message
      normalized_temperature = maybe_normalize_temperature(temperature, model)

      payload = Utils.deep_merge(
        render_payload(
          messages,
          tools: tools,
          temperature: normalized_temperature,
          model: model,
          stream: false,
          schema: schema,
          thinking: thinking,
          tool_prefs: tool_prefs
        ),
        params
      )

      sync_response(payload.to_json, headers)
    end

    # The chat-completion request pipeline (streaming). Same as the sync overload
    # but renders with `stream: true` and delegates to the `Streaming` mixin's
    # `stream_response`, yielding each Chunk to the block. Returns the final
    # assembled Message.
    def complete(messages : Array(Message), tools : Hash(String, Tool),
                 temperature : Float64?, model : Model::Info,
                 params : Hash(String, JSON::Any) = {} of String => JSON::Any,
                 headers : Hash(String, String) = {} of String => String,
                 schema : JSON::Any? = nil,
                 thinking : Thinking::Config? = nil,
                 tool_prefs : Hash(String, String?)? = nil,
                 &block : Chunk ->) : Message
      normalized_temperature = maybe_normalize_temperature(temperature, model)

      payload = Utils.deep_merge(
        render_payload(
          messages,
          tools: tools,
          temperature: normalized_temperature,
          model: model,
          stream: true,
          schema: schema,
          thinking: thinking,
          tool_prefs: tool_prefs
        ),
        params
      )

      stream_response(payload.to_json, headers, &block)
    end

    # POSTs the rendered payload to the completion endpoint and parses the
    # response. Mirrors ruby_llm's private `sync_response`.
    #
    # Per-request signing: `sign_headers(method, url, body)` is a provider hook that
    # returns extra request headers computed from the outgoing call (the base returns
    # `{}`). Bedrock overrides it to compute AWS SigV4 (`Authorization`/`X-Amz-*`).
    # The signed headers are merged *under* caller `headers` (caller wins on conflict),
    # mirroring ruby_llm's `req.headers.merge!(signed_headers)` in `signed_post`.
    def sync_response(payload : String, headers : Hash(String, String) = {} of String => String) : Message
      url = completion_url
      signed = sign_headers("POST", url, payload).merge(headers)
      response = connection.post(url, payload, signed)
      parse_completion_response(response)
    end

    # Fetches and parses the provider's model list. Mirrors ruby_llm's `list_models`.
    # The list-models GET is signed the same way (ruby_llm's `signed_get`).
    def list_models : Array(Model::Info)
      url = models_url
      signed = sign_headers("GET", url, "")
      response = connection.get(url, signed)
      parse_list_models_response(response, slug, self.class.capabilities)
    end

    # ---- Provider hooks the completion pipeline dispatches to (raising stubs) ----
    #
    # Each concrete provider overrides these. (api_base/headers/stream_url/build_chunk
    # already live on provider.cr; these are the completion-pipeline additions.)

    # Path (relative to api_base) for the chat-completions endpoint.
    def completion_url : String
      raise "completion_url must be implemented by #{self.class.provider_name}"
    end

    # Builds the provider request body. `stream` toggles streaming-specific fields.
    # `tool_prefs` is Chat's tool-choice state (`{"choice" => ..., "calls" => ...}`)
    # or `nil` for "no preference"; each provider emits its wire-specific tool_choice.
    def render_payload(messages : Array(Message), tools : Hash(String, Tool),
                       temperature : Float64?, model : Model::Info,
                       stream : Bool = false, schema : JSON::Any? = nil,
                       thinking : Thinking::Config? = nil,
                       tool_prefs : Hash(String, String?)? = nil) : Hash(String, JSON::Any)
      raise "render_payload must be implemented by #{self.class.provider_name}"
    end

    # Parses a completed (non-streaming) response body into a Message.
    def parse_completion_response(response : Crest::Response) : Message
      raise "parse_completion_response must be implemented by #{self.class.provider_name}"
    end

    # Formats CrystalLLM messages into the provider's wire shape.
    def format_messages(messages : Array(Message)) : Array(JSON::Any)
      messages.map do |msg|
        JSON::Any.new({
          "role"    => JSON::Any.new(msg.role.to_s.downcase),
          "content" => content_to_json(msg.content),
        } of String => JSON::Any)
      end
    end

    # Default no-op formatters (ruby_llm returns nil; concrete providers override).
    def format_tool_calls(tool_calls : Hash(String, ToolCall)?) : JSON::Any?
      nil
    end

    def parse_tool_calls(tool_calls : JSON::Any?) : Hash(String, ToolCall)?
      nil
    end

    # Path (relative to api_base) for the list-models endpoint.
    def models_url : String
      raise "models_url must be implemented by #{self.class.provider_name}"
    end

    # Parses a list-models response into Model::Info records.
    def parse_list_models_response(response : Crest::Response, slug : String,
                                   capabilities : Capabilities.class) : Array(Model::Info)
      raise "parse_list_models_response must be implemented by #{self.class.provider_name}"
    end

    # Temperature normalization hook (OpenAI overrides; base is identity).
    def maybe_normalize_temperature(temperature : Float64?, model : Model::Info) : Float64?
      temperature
    end

    # Per-request signing hook (default no-op). Returns extra headers to merge into a
    # request, computed from the outgoing method/url/body so the body is available at
    # signing time. The base returns an empty Hash (no signing). AWS Bedrock overrides
    # this to compute SigV4 (`Authorization` + `X-Amz-Date`/`X-Amz-Content-Sha256`).
    #
    # ruby_llm models this differently — Bedrock overrides `sync_response`/`list_models`
    # to call `signed_post`/`signed_get`, which merge `sign_headers(...)` into the
    # request inline. The Crystal port keeps the frozen sync/list pipeline and hoists
    # the merge there (provider_completion.cr / streaming.cr), so any provider can opt
    # into per-request signing by overriding this single hook.
    def sign_headers(method : String, url : String, body : String) : Hash(String, String)
      {} of String => String
    end

    # The provider's capability helper. ruby_llm: `self.class.capabilities`
    # returns a module; here it is a `Capabilities` subclass (or the base, which
    # answers conservatively). Overridden by concrete providers.
    def self.capabilities : Capabilities.class
      Capabilities
    end

    # JSON-wraps a Message's content (String text or nil) for `format_messages`.
    # Rich Content (attachments) formatting is provider-specific (OpenAI overrides).
    private def content_to_json(content : String | Content | Content::Raw | Nil) : JSON::Any
      case content
      when String       then JSON::Any.new(content)
      when Content::Raw then content.value # provider-native blocks pass through
      when Nil          then JSON::Any.new(nil)
      else                   JSON::Any.new(content.to_s)
      end
    end
  end

  # Base capability helper. ruby_llm's per-provider `Capabilities` is a module of
  # `module_function`s; the Crystal port models it as a class hierarchy so a
  # provider's `capabilities` can be passed around as a `Capabilities.class` and
  # answered via class methods. The base answers conservatively; concrete
  # providers (e.g. Providers::OpenAI::Capabilities) subclass and override.
  class Capabilities
    def self.context_window_for(model_id : String) : Int32?
      nil
    end

    def self.max_tokens_for(model_id : String) : Int32?
      nil
    end

    def self.critical_capabilities_for(model_id : String) : Array(String)
      [] of String
    end

    def self.pricing_for(model_id : String) : Hash(String, JSON::Any)
      {} of String => JSON::Any
    end
  end
end
