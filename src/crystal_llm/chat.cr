# ported from lib/ruby_llm/chat.rb @ ruby_llm 1.15.0
#
# The Chat builder + completion flow: a chainable conversation object that
# accumulates messages, tools, and per-call options, then drives the provider
# completion pipeline (Provider#complete) and the tool-call loop.
#
# == Divergences from ruby_llm (documented) ==
#
# * Tools are a `Hash(String, Tool)` keyed by the tool's `name` (a String), not
#   ruby_llm's `Symbol`-keyed hash (symbols-as-runtime-data → String, design §11).
#   `with_tool` accepts a `Tool` instance only — ruby_llm also accepts a tool
#   *class* (`tool.is_a?(Class) ? tool.new : tool`); Crystal cannot `.new` an
#   arbitrary `Tool.class` with no shared zero-arg constructor contract, so the
#   caller instantiates. (DynamicTool / macro tools both produce instances.)
#
# * Callbacks: the **modern** additive form is ported —
#   `before_message`/`after_message`/`before_tool_call`/`after_tool_result`, each
#   stacking blocks in `@callbacks`. The **legacy** single-slot `on_new_message` /
#   `on_end_message` / `on_tool_call` / `on_tool_result` aliases (deprecated in
#   ruby_llm, removed in 2.0) are now ported as deprecation-emitting *aliases* that
#   register into the modern additive arrays (rather than ruby_llm's parallel
#   single-slot `@on` dispatch). See the "legacy single-slot aliases" section.
#
# * `complete` has no `block_given?`: it is two overloads (sync returning Message,
#   streaming taking `&block : CrystalLLM::Chunk ->`) mirroring Provider#complete. The
#   completion loop (`complete_once` / `handle_tool_calls`) is duplicated across
#   the two so the streaming block threads through correctly.
#
# * Instrumentation: `complete` wraps `complete_once` in `instrument_completion`,
#   emitting a `chat.crystal_llm` event (model / messages / tools / token counts)
#   through the configured `Configuration#instrumenter` (a no-op when none is set,
#   so behaviour is unchanged). Tool execution emits `tool_call.crystal_llm` via
#   `execute_tool`. ruby_llm's event names are `chat.ruby_llm` / `tool_call.ruby_llm`;
#   the port renames the suffix to `crystal_llm` (documented divergence).
#
# * `with_schema` accepts a raw json-schema (`JSON::Any` / `Hash(String,
#   JSON::Any)`) OR a `CrystalLLM::Schema` instance (→ `to_json_schema`). The
#   normalized payload is the `{name, schema, strict}` envelope `Provider`'s
#   render_payload reads via `as_h?`. The typed `with_schema(T)` / `ask_as(msg, T)`
#   hatch is now ported as `forall T` overloads that derive the schema from `T`'s
#   instance vars and deserialize via `T.from_json` (see the typed-hatch section).
#
# * Cost aggregation (`Chat#cost` → `Cost.aggregate`) is ported: `#cost` sums each
#   message's cost via `Cost.aggregate` (see `#cost` below).
#
# * `tool_prefs` (`:choice` / `:calls`): the per-call tool-choice preference and
#   the tool-call *limit* are ported as Chat state AND forwarded to the provider —
#   `complete_once` passes `@tool_prefs` through `Provider#complete` →
#   `render_payload`, where each provider emits its wire-specific tool_choice /
#   parallel control. The `:calls` limit ("one" vs "many") additionally drives the
#   forced-tool-choice reset in the tool loop here (`reset_tool_choice` after a
#   forced call, so the next turn isn't re-forced).
#
# * `@context` / `@config`: a Chat resolves its provider through the (optional)
#   Context's config, falling back to `CrystalLLM.config`. `with_context` re-binds
#   the provider with `assume_exists: true` (ruby_llm parity).
require "json"
require "./message"
require "./content"
require "./tool"
require "./tool_call"
require "./thinking"
require "./cost"
require "./schema"
require "./models"
require "./model/info"
require "./provider"
require "./provider_completion"
require "./configuration"
require "./context"
require "./error"
require "./instrumentation"

module CrystalLLM
  # Represents a conversation with an AI model.
  class Chat
    include Enumerable(Message)

    getter model : Model::Info
    getter messages : Array(Message)
    getter tools : Hash(String, Tool)
    # Tool-choice preference state. `:choice` (a String? tool name / "auto" /
    # "none" / "required") is forwarded to the provider via `complete_once` →
    # `Provider#complete`. `:calls` is the call limit as a String? ("one"/"many").
    getter tool_prefs : Hash(String, String?)
    getter params : Hash(String, JSON::Any)
    getter headers : Hash(String, String)
    getter schema : JSON::Any?

    @context : Context?
    @config : Configuration
    @provider : Provider
    @temperature : Float64?
    @thinking : Thinking::Config?

    # Stacked, additive callbacks (modern form). Keyed by callback name; each
    # value is a list of blocks. ruby_llm uses a `Hash.new { [] }` default-proc;
    # Crystal needs explicit initialization per key.
    @callbacks : Hash(String, Array(Message ->))
    @tool_call_callbacks : Hash(String, Array(ToolCall ->))
    @tool_result_callbacks : Hash(String, Array(ToolResult ->))

    def initialize(model : String? = nil, provider : String? = nil,
                   assume_model_exists : Bool = false, context : Context? = nil)
      if assume_model_exists && !provider
        raise ArgumentError.new("Provider must be specified if assume_model_exists is true")
      end

      @context = context
      @config = context.try(&.config) || CrystalLLM.config
      model_id = model || @config.default_model

      # Initialize all collection/option ivars BEFORE resolving the model, so the
      # `with_model` call (which Crystal's nil-analysis treats as able to touch any
      # ivar) sees a fully-initialized object. @model/@provider are assigned by
      # `resolve_model` below.
      @temperature = nil
      @messages = [] of Message
      @tools = {} of String => Tool
      @tool_prefs = {"choice" => nil, "calls" => nil} of String => String?
      @params = {} of String => JSON::Any
      @headers = {} of String => String
      @schema = nil
      @thinking = nil
      @callbacks = Hash(String, Array(Message ->)).new
      @tool_call_callbacks = Hash(String, Array(ToolCall ->)).new
      @tool_result_callbacks = Hash(String, Array(ToolResult ->)).new

      @model, @provider = resolve_model(model_id, provider, assume_model_exists)
    end

    # Resolves a model id → {Model::Info, Provider instance}. Shared by initialize
    # and `with_model` (the latter assigns the result + returns self).
    private def resolve_model(model_id : String, provider : String?,
                              assume_exists : Bool) : {Model::Info, Provider}
      info = Models.resolve(model_id, provider: provider, assume_exists: assume_exists)

      provider_slug = provider || info.provider
      raise ModelNotFoundError.new("Could not determine provider for model #{model_id.inspect}") unless provider_slug

      provider_class = Provider.resolve(provider_slug)
      unless provider_class
        raise ModelNotFoundError.new(
          "Unknown provider: #{provider_slug.inspect}. " \
          "Register it with `CrystalLLM::Provider.register`."
        )
      end

      {info, provider_class.new(@config)}
    end

    # ---- Asking ------------------------------------------------------------

    # Adds a user message and runs a completion (sync). `with` carries attachments.
    # Returns the assistant `Message`, OR a `Tool::Halt` when a tool halted the
    # conversation (mirrors ruby_llm, where `handle_tool_calls` returns the
    # `Tool::Halt` result rather than running a follow-up completion).
    def ask(message : String? = nil, with attachments : Attachable? = nil) : Message | Tool::Halt
      add_message(role: Role::User, content: build_content(message, attachments))
      complete
    end

    # Streaming overload: yields each Chunk to the block.
    def ask(message : String? = nil, with attachments : Attachable? = nil, &block : CrystalLLM::Chunk ->) : Message | Tool::Halt
      add_message(role: Role::User, content: build_content(message, attachments))
      complete(&block)
    end

    # `say` is an alias for `ask` (ruby_llm: `alias say ask`).
    def say(message : String? = nil, with attachments : Attachable? = nil) : Message | Tool::Halt
      ask(message, with: attachments)
    end

    def say(message : String? = nil, with attachments : Attachable? = nil, &block : CrystalLLM::Chunk ->) : Message | Tool::Halt
      ask(message, with: attachments, &block)
    end

    # ---- Chainable builders ------------------------------------------------

    # Sets/append a system instruction. `append: true` keeps existing system
    # messages and adds another; the default replaces them. (ruby_llm's
    # `replace:` legacy keyword is folded into `append:` — append is the modern
    # name; pass `append: true` to add.)
    def with_instructions(instructions : String, append : Bool = false) : self
      if append
        append_system_instruction(instructions)
      else
        replace_system_instruction(instructions)
      end
      self
    end

    # Registers a tool, keyed by its `name`. `choice`/`calls` update tool_prefs.
    def with_tool(tool : Tool?, choice : String? = nil, calls : String? = nil) : self
      if t = tool
        @tools[t.name] = t
      end
      update_tool_options(choice, calls)
      self
    end

    # Registers many tools. `replace: true` clears existing tools first.
    def with_tools(*tools : Tool?, replace : Bool = false,
                   choice : String? = nil, calls : String? = nil) : self
      @tools.clear if replace
      tools.each { |tool| with_tool(tool) if tool }
      update_tool_options(choice, calls)
      self
    end

    # Resolves the model id → Model::Info + provider class, and instantiates the
    # provider with the current config. ruby_llm's `Models.resolve` returns the
    # provider *instance* too; this port resolves the Model::Info via
    # `Models.resolve` and the Provider class via `Provider.resolve`, then
    # instantiates it with `@config`.
    def with_model(model_id : String, provider : String? = nil, assume_exists : Bool = false) : self
      @model, @provider = resolve_model(model_id, provider, assume_exists)
      self
    end

    def with_temperature(temperature : Float64) : self
      @temperature = temperature
      self
    end

    # Enables thinking. Requires `effort` or `budget` (ruby_llm parity).
    def with_thinking(effort : String? = nil, budget : Int32? = nil) : self
      if effort.nil? && budget.nil?
        raise ArgumentError.new("with_thinking requires effort or budget")
      end
      @thinking = Thinking::Config.new(effort: effort, budget: budget)
      self
    end

    # Re-binds the chat to a new Context's config, re-resolving the provider.
    def with_context(context : Context) : self
      @context = context
      @config = context.config
      slug = @provider.slug
      with_model(@model.id || @config.default_model, provider: slug, assume_exists: true)
      self
    end

    # Replaces the per-call params merged over the provider payload.
    def with_params(params : Hash(String, JSON::Any)) : self
      @params = params
      self
    end

    # Replaces the per-call request headers.
    def with_headers(headers : Hash(String, String)) : self
      @headers = headers
      self
    end

    # Sets the structured-output schema. Accepts a `CrystalLLM::Schema` instance
    # (→ `to_json_schema`) or a raw json-schema (`JSON::Any` / `Hash`). The result
    # is normalized to the `{name, schema, strict}` envelope.
    def with_schema(schema : Schema) : self
      @schema = normalize_schema_payload(schema.to_json_schema)
      self
    end

    def with_schema(schema : Hash(String, JSON::Any)) : self
      @schema = normalize_schema_payload(schema)
      self
    end

    def with_schema(schema : JSON::Any) : self
      # ruby_llm passes a raw schema through (it duck-types on `to_json_schema` /
      # Hash). A non-object JSON envelope (array/scalar) has no schema shape to
      # normalize; silently dropping it to nil hides a caller error, so raise
      # instead of swallowing it.
      hash = schema.as_h?
      raise ArgumentError.new(
        "with_schema(JSON::Any) requires a JSON object schema, got #{schema.raw.class}"
      ) if hash.nil?
      @schema = normalize_schema_payload(hash)
      self
    end

    # ---- Typed structured-output hatch (APPROVED additive divergence) ------
    #
    # ruby_llm passes a *schema class* to `with_schema`/`ask` and reads the result
    # back as a parsed Hash. Crystal can't store an arbitrary type as runtime state
    # and can't change `ask`'s return type from instance state, so the typed path is
    # an additive pair (design §"Structured output (R3)" / PORTING.md #11):
    #
    #   * `with_schema(T)` — a `forall T` overload that derives a JSON schema from
    #     `T`'s instance vars and sets it as the response_format schema; returns
    #     `self`. (Content read via `ask` + manual `T.from_json`.)
    #   * `ask_as(message, T)` — `with_schema(T)`, run `ask`, then deserialize the
    #     assistant message's String content via `T.from_json`, returning a `T`.
    #
    # These are real method overloads — the `T.class` argument is distinct from the
    # `Schema` / `Hash` / `JSON::Any` overloads above, so they coexist. (A macro of
    # the same name would be shadowed by the existing methods: Crystal only falls
    # back to a same-named macro when NO method matches the call arity.) `T` must
    # include `JSON::Serializable`. The schema is derived inside the `forall T` body
    # by walking `T.instance_vars` (a compile-time reflection that resolves to
    # concrete code per instantiated `T` — the ordinary-method-body context where
    # `instance_vars` is legal): each ivar becomes a property; nilable ivars are
    # optional, the rest required. The wire property name honors any
    # `@[JSON::Field(key: "...")]` annotation. The raw `JSON::Any` / `Hash` /
    # `Schema` paths above are untouched.

    # Sets a typed schema derived from struct type `T` and returns `self`.
    def with_schema(klass : T.class) : self forall T
      with_schema(derive_typed_schema(klass))
    end

    # Runs `ask` constrained to schema `T` and deserializes the response into a `T`.
    # The assistant message content is a JSON String (the schema constrains the
    # provider to emit one); `T.from_json` does the authoritative typing.
    def ask_as(message : String?, klass : T.class, with attachments : Attachable? = nil) : T forall T
      response = with_schema(klass).ask(message, with: attachments)
      # A schema-constrained ask returns a Message; a Tool::Halt has no JSON content
      # to deserialize (no tools are registered on this path, but guard regardless).
      unless response.is_a?(Message)
        raise SchemaResponseError.new(
          "ask_as(#{T}) expected a Message response, got #{response.class}"
        )
      end
      content = response.content
      unless content.is_a?(String)
        raise SchemaResponseError.new(
          "ask_as(#{T}) expected a String JSON response, got #{content.class}"
        )
      end
      T.from_json(content)
    end

    # Derives the `{name, schema}` envelope (`Hash(String, JSON::Any)`) for struct
    # type `T`. Walks `T.instance_vars`: each ivar is a property keyed by its
    # `@[JSON::Field(key:)]` (or ivar name); non-nilable ivars are `required`. The
    # `instance_vars` walk runs in this `forall T` body (an ordinary method body —
    # the place `instance_vars` resolves; see the crystal macros reference).
    private def derive_typed_schema(klass : T.class) : Hash(String, JSON::Any) forall T
      properties = {} of String => JSON::Any
      required = [] of JSON::Any

      {% for ivar in T.instance_vars %}
        {%
          ann = ivar.annotation(::JSON::Field)
          key = (ann && ann[:key]) ? ann[:key] : ivar.name.stringify
          it = ivar.type
          # Drop Nil from a union so e.g. `String?` schemas as a plain string; the
          # nilability is encoded as "not required" in the parent object.
          non_nil = it.union? ? it.union_types.reject(&.==(Nil)) : [it]
          single = non_nil.size == 1 ? non_nil[0] : nil
          nilable = it.nilable?
        %}
        {% if single == nil %}
          # A multi-member (non-nilable) union has no single JSON type — emit an
          # unconstrained object; from_json does the authoritative typing.
          properties[{{key}}] = JSON::Any.new({"type" => JSON::Any.new("object")} of String => JSON::Any)
        {% else %}
          properties[{{key}}] = JSON::Any.new(json_fragment_for({{single}}))
        {% end %}
        {% unless nilable %}
          required << JSON::Any.new({{key}})
        {% end %}
      {% end %}

      schema = {} of String => JSON::Any
      schema["type"] = JSON::Any.new("object")
      schema["properties"] = JSON::Any.new(properties)
      schema["required"] = JSON::Any.new(required)
      schema["additionalProperties"] = JSON::Any.new(false)

      envelope = {} of String => JSON::Any
      envelope["name"] = JSON::Any.new(self.class.schema_name_for({{ T.name(generic_args: false).stringify }}))
      envelope["schema"] = JSON::Any.new(schema)
      envelope
    end

    # Maps a single (non-union) Crystal type to a JSON-schema fragment
    # `Hash(String, JSON::Any)`. Recurses into `Array(T)` for the item schema.
    # `Hash`/struct/unknown types fall back to an unconstrained object — the
    # provider still gets a valid schema, and `from_json` does the real typing.
    # `type_node` is interpolated as a type reference (a `Path`), so `.resolve`
    # turns it back into a `TypeNode`.
    macro json_fragment_for(type_node)
      {% begin %}
        {% base = type_node.resolve %}
        {% if base <= String %}
          {"type" => JSON::Any.new("string")} of String => JSON::Any
        {% elsif base <= Bool %}
          {"type" => JSON::Any.new("boolean")} of String => JSON::Any
        {% elsif base <= Int %}
          {"type" => JSON::Any.new("integer")} of String => JSON::Any
        {% elsif base <= Float %}
          {"type" => JSON::Any.new("number")} of String => JSON::Any
        {% elsif base <= Array %}
          {
            "type"  => JSON::Any.new("array"),
            "items" => JSON::Any.new(CrystalLLM::Chat.json_fragment_for({{ base.type_vars[0] }})),
          } of String => JSON::Any
        {% else %}
          {"type" => JSON::Any.new("object")} of String => JSON::Any
        {% end %}
      {% end %}
    end

    # Sanitizes a derived struct name into a schema name (drops namespace `::`,
    # keeps schema-name-safe chars). Class-level so `derive_typed_schema` can reach
    # it as `self.class.schema_name_for`.
    def self.schema_name_for(name : String) : String
      bare = name.split("::").last
      sanitized = bare.gsub(/[^a-zA-Z0-9_-]/, "_")
      sanitized.empty? ? "response" : sanitized
    end

    # ---- Callbacks (modern, additive) --------------------------------------

    def before_message(&block : Message ->) : self
      add_message_callback("before_message", &block)
    end

    def after_message(&block : Message ->) : self
      add_message_callback("after_message", &block)
    end

    def before_tool_call(&block : ToolCall ->) : self
      (@tool_call_callbacks["before_tool_call"] ||= [] of ToolCall ->) << block
      self
    end

    def after_tool_result(&block : ToolResult ->) : self
      (@tool_result_callbacks["after_tool_result"] ||= [] of ToolResult ->) << block
      self
    end

    # ---- Callbacks (legacy single-slot aliases, deprecated) ----------------
    #
    # ruby_llm keeps `on_new_message` / `on_end_message` / `on_tool_call` /
    # `on_tool_result` working but deprecated (removed in 2.0). It stores them in a
    # separate single-slot `@on` hash dispatched alongside the additive callbacks.
    #
    # DIVERGENCE: rather than maintaining a parallel single-slot dispatch path, the
    # port registers each legacy callback as an *alias* into the corresponding
    # modern additive array (`on_new_message` → `before_message`, etc.). This is
    # behaviourally equivalent for the supported single-registration use (the block
    # fires at the same point) and reuses the existing dispatch. Each call emits the
    # same deprecation warning ruby_llm does, via the configured `Deprecator`. The
    # only observable difference from ruby_llm: registering twice STACKS (both run)
    # instead of last-wins — additive semantics, which is strictly more forgiving.

    def on_new_message(&block : Message ->) : self
      warn_legacy_callback("on_new_message", "before_message")
      before_message(&block)
    end

    def on_end_message(&block : Message ->) : self
      warn_legacy_callback("on_end_message", "after_message")
      after_message(&block)
    end

    def on_tool_call(&block : ToolCall ->) : self
      warn_legacy_callback("on_tool_call", "before_tool_call")
      before_tool_call(&block)
    end

    def on_tool_result(&block : ToolResult ->) : self
      warn_legacy_callback("on_tool_result", "after_tool_result")
      after_tool_result(&block)
    end

    private def warn_legacy_callback(legacy_name : String, additive_name : String) : Nil
      CrystalLLM.deprecator.warn(
        "`#{legacy_name}` is deprecated and will be removed in CrystalLLM 2.0. " \
        "Use `#{additive_name}` instead."
      )
    end

    # ---- Enumerable + message access ---------------------------------------

    def each(& : Message ->) : Nil
      @messages.each { |message| yield message }
    end

    # Appends a Message (from a built instance or constructor kwargs) and returns it.
    def add_message(message : Message) : Message
      @messages << message
      message
    end

    def add_message(role : Role | Symbol | String, content : String | Content | Nil = nil,
                    tool_call_id : String? = nil,
                    tool_calls : Hash(String, ToolCall)? = nil) : Message
      message = Message.new(role: role, content: content,
        tool_call_id: tool_call_id, tool_calls: tool_calls)
      add_message(message)
    end

    # Removes all in-memory messages (ruby_llm's `reset_messages!`).
    def reset_messages! : Nil
      @messages.clear
    end

    # ---- Completion (sync) -------------------------------------------------

    def complete : Message | Tool::Halt
      instrument_completion(streaming: false) { complete_once }
    end

    # ---- Completion (streaming) --------------------------------------------

    def complete(&block : CrystalLLM::Chunk ->) : Message | Tool::Halt
      instrument_completion(streaming: true) { complete_once(&block) }
    end

    # Wraps a completion run in a `chat.crystal_llm` instrumentation event. Builds
    # the request-side payload (model / messages / tools / options), runs the work,
    # then attaches the response-side keys (response, token counts, tool calls) to
    # the same event — mirroring ruby_llm's `instrument_completion`. When no
    # instrumenter is configured this is a transparent no-op: the block runs and its
    # result is returned untouched.
    private def instrument_completion(streaming : Bool, &block : -> (Message | Tool::Halt)) : Message | Tool::Halt
      payload = build_chat_payload(streaming)
      CrystalLLM.instrument("chat.crystal_llm", payload, config: @config) do |event|
        result = block.call
        event["response"] = result
        event["messages_after"] = @messages.dup
        # ruby_llm guards the response-side Message keys with
        # `if result.respond_to?(:tool_call?)` — a `Tool::Halt` result has none of
        # them. The port mirrors that: only a `Message` carries role/tokens/etc.
        if result.is_a?(Message)
          event["response_role"] = result.role.to_s
          event["response_model"] = result.model_id
          event["tool_call"] = result.tool_call?
          event["tool_calls"] = result.tool_calls
          event["input_tokens"] = result.input_tokens
          event["output_tokens"] = result.output_tokens
          event["cached_tokens"] = result.cached_tokens
          event["cache_creation_tokens"] = result.cache_creation_tokens
          event["thinking_tokens"] = result.thinking_tokens
        end
        result
      end
    end

    # The request-side `chat.crystal_llm` payload. Mirrors ruby_llm's payload keys
    # (symbol → String). `chat` carries `self` so a sink can introspect the run.
    private def build_chat_payload(streaming : Bool) : Instrumentation::Payload
      payload = Instrumentation::Payload.new
      payload["chat"] = self
      payload["provider"] = @provider.slug
      payload["provider_class"] = @provider.class
      payload["model"] = @model.id
      payload["model_info"] = @model
      payload["input_messages"] = @messages.dup
      payload["message_count"] = @messages.size
      payload["tools"] = @tools.keys
      payload["tool_choice"] = @tool_prefs["choice"]?
      payload["tool_call_limit"] = @tool_prefs["calls"]?
      payload["temperature"] = @temperature
      payload["params"] = JSON::Any.new(@params)
      payload["schema"] = @schema
      payload["thinking"] = @thinking
      payload["streaming"] = streaming
      payload
    end

    # Aggregate cost across all messages. Mirrors ruby_llm's
    # `Cost.aggregate(messages.map(&:cost))`.
    def cost : Cost
      Cost.aggregate(@messages.map(&.cost.as(Cost?)))
    end

    private def complete_once : Message | Tool::Halt
      response = @provider.complete(
        @messages,
        tools: @tools,
        temperature: @temperature,
        model: @model,
        params: @params,
        headers: @headers,
        schema: @schema,
        thinking: @thinking,
        tool_prefs: @tool_prefs
      )

      run_message_callbacks("before_message", response) # mirror ruby_llm's non-stream path
      normalize_schema_response(response)
      add_message(response)
      run_message_callbacks("after_message", response)

      if response.tool_call?
        handle_tool_calls(response)
      else
        response
      end
    end

    private def complete_once(&block : CrystalLLM::Chunk ->) : Message | Tool::Halt
      run_message_callbacks("before_message", nil)

      response = @provider.complete(
        @messages,
        tools: @tools,
        temperature: @temperature,
        model: @model,
        params: @params,
        headers: @headers,
        schema: @schema,
        thinking: @thinking,
        tool_prefs: @tool_prefs,
        &block
      )

      normalize_schema_response(response)
      add_message(response)
      run_message_callbacks("after_message", response)

      if response.tool_call?
        handle_tool_calls(response, &block)
      else
        response
      end
    end

    # ---- Tool-call loop ----------------------------------------------------

    private def handle_tool_calls(response : Message) : Message | Tool::Halt
      halt_result = run_tool_calls(response)
      reset_tool_choice if forced_tool_choice?
      # ruby_llm: `halt_result || complete(&)` — return the Tool::Halt result
      # itself (no follow-up completion) when a tool halted, else continue the loop.
      if halt = halt_result
        halt
      else
        complete
      end
    end

    private def handle_tool_calls(response : Message, &block : CrystalLLM::Chunk ->) : Message | Tool::Halt
      halt_result = run_tool_calls(response)
      reset_tool_choice if forced_tool_choice?
      if halt = halt_result
        halt
      else
        complete(&block)
      end
    end

    # Executes each tool call in the response, appending a tool-role result
    # message for each. Returns the `Tool::Halt` result if a tool requested a halt
    # (mirroring ruby_llm's `halt_result = result`), else nil (signalling the loop
    # should continue to another completion). The halt content is STILL appended as
    # a tool-role message before returning.
    private def run_tool_calls(response : Message) : Tool::Halt?
      halt_result : Tool::Halt? = nil
      tool_calls = response.tool_calls
      return nil unless tool_calls

      tool_calls.each_value do |tool_call|
        run_message_callbacks("before_message", nil)
        run_tool_call_callbacks(tool_call)
        result = execute_tool(tool_call)
        run_tool_result_callbacks(result)

        if result.is_a?(Tool::Halt)
          tool_payload = result.content
        else
          tool_payload = result
        end

        content = content_for_message(tool_payload)
        message = add_message(role: Role::Tool, content: content, tool_call_id: tool_call.id)
        run_message_callbacks("after_message", message)

        halt_result = result if result.is_a?(Tool::Halt)
      end

      halt_result
    end

    private def execute_tool(tool_call : ToolCall) : ToolResult
      tool = @tools[tool_call.name]?
      if tool.nil?
        return {
          "error" => JSON::Any.new(
            "Model tried to call unavailable tool `#{tool_call.name}`. " \
            "Available tools: #{@tools.keys.to_json}."
          ),
        } of String => JSON::Any
      end

      instrument_tool_call(tool, tool_call) { tool.call(tool_call.arguments) }
    end

    # Wraps a single tool invocation in a `tool_call.crystal_llm` event, attaching
    # the result to the event after the call. Mirrors ruby_llm's `execute_tool`
    # instrumentation. No-op (just runs the block) when no instrumenter is set.
    private def instrument_tool_call(tool : Tool, tool_call : ToolCall, &block : -> ToolResult) : ToolResult
      payload = Instrumentation::Payload.new
      payload["chat"] = self
      payload["provider"] = @provider.slug
      payload["provider_class"] = @provider.class
      payload["model"] = @model.id
      payload["model_info"] = @model
      payload["tool"] = tool
      payload["tool_call"] = tool_call
      payload["tool_name"] = tool.name
      payload["tool_arguments"] = JSON::Any.new(tool_call.arguments)
      payload["tool_call_id"] = tool_call.id

      CrystalLLM.instrument("tool_call.crystal_llm", payload, config: @config) do |event|
        result = block.call
        event["result"] = result
        event["result_content"] = result.is_a?(Tool::Halt) ? result.content : result
        result
      end
    end

    # ---- Content + schema helpers ------------------------------------------

    private def build_content(message : String?, attachments : Attachable?) : String | Content | Nil
      # Bare-string fast path: a plain message with no attachments is "content-like"
      # in ruby_llm and passes through untouched.
      return message if !message.nil? && attachments.nil?

      # Otherwise construct Content (matches ruby_llm's `Content.new(message,
      # attachments)`). When BOTH message and attachments are nil this deliberately
      # lets Content.new raise the both-nil ArgumentError rather than swallowing it.
      Content.new(message, attachments)
    end

    # Turns a tool result payload into message content (String or Content).
    private def content_for_message(payload : ToolResult) : String | Content
      case payload
      when String                  then payload
      when Content                 then payload
      when Hash(String, JSON::Any) then payload.to_json
      when Tool::Halt
        # A Halt wrapping another payload (nested halt) — render its content.
        content_for_message(payload.content)
      else
        payload.to_s
      end
    end

    # Parses a String response into JSON when a schema was requested (matches
    # ruby_llm's `normalize_schema_response`). On parse failure, keeps the string.
    private def normalize_schema_response(response : Message) : Nil
      return unless @schema
      return if response.tool_call?
      content = response.content
      return unless content.is_a?(String)

      JSON.parse(content)
      # The parse succeeding means the content is valid JSON; ruby_llm replaces
      # `response.content` with the parsed object. The port's Message#content is a
      # String here (no JSON::Any content variant), so we leave the raw JSON string
      # in place — downstream callers parse it. Documented divergence.


    rescue JSON::ParseException
      # keep content as the original string
    end

    # Normalizes a raw schema into the `{name, schema, strict}` envelope (ruby_llm's
    # `normalize_schema_payload`). Returns the envelope as a `JSON::Any`.
    private def normalize_schema_payload(raw : Hash(String, JSON::Any)?) : JSON::Any?
      return nil if raw.nil?

      # If the raw hash is already an envelope (has a `schema` key), pull the inner
      # schema; otherwise treat the whole hash as the schema definition.
      inner = raw["schema"]?.try(&.as_h?) || raw
      strict = extract_strict(raw, inner)
      name = sanitize_schema_name(raw["name"]?.try(&.as_s?) || "response")

      schema_def = inner.dup
      schema_def.delete("strict")

      envelope = {} of String => JSON::Any
      envelope["name"] = JSON::Any.new(name)
      envelope["schema"] = JSON::Any.new(schema_def)
      envelope["strict"] = JSON::Any.new(strict)
      if desc = raw["description"]?.try(&.as_s?)
        envelope["description"] = JSON::Any.new(desc)
      end
      JSON::Any.new(envelope)
    end

    private def extract_strict(raw : Hash(String, JSON::Any), inner : Hash(String, JSON::Any)) : Bool
      if s = raw["strict"]?
        return s.as_bool? != false
      end
      if s = inner["strict"]?
        return s.as_bool? != false
      end
      true
    end

    private def sanitize_schema_name(name : String) : String
      sanitized = name.gsub(/[^a-zA-Z0-9_-]/, "_")
      sanitized.empty? ? "response" : sanitized
    end

    # ---- Tool option / choice helpers --------------------------------------

    private def update_tool_options(choice : String?, calls : String?) : Nil
      unless choice.nil?
        normalized = choice
        valid = ["auto", "none", "required"] + @tools.keys
        unless valid.includes?(normalized)
          raise InvalidToolChoiceError.new(
            "Invalid tool choice: #{choice}. Valid choices are: #{valid.join(", ")}"
          )
        end
        @tool_prefs["choice"] = normalized
      end

      @tool_prefs["calls"] = normalize_calls(calls) unless calls.nil?
    end

    private def normalize_calls(calls : String) : String
      case calls
      when "many"     then "many"
      when "one", "1" then "one"
      else
        raise ArgumentError.new(
          "Invalid calls value: #{calls.inspect}. Valid values are: \"many\", \"one\", or \"1\""
        )
      end
    end

    private def forced_tool_choice? : Bool
      choice = @tool_prefs["choice"]?
      !choice.nil? && !["auto", "none"].includes?(choice)
    end

    private def reset_tool_choice : Nil
      @tool_prefs["choice"] = nil
    end

    # ---- System-instruction helpers ----------------------------------------

    private def append_system_instruction(instructions : String) : Nil
      system_messages = @messages.select(&.role.system?)
      non_system = @messages.reject(&.role.system?)
      system_messages << Message.new(role: Role::System, content: instructions)
      @messages = system_messages + non_system
    end

    private def replace_system_instruction(instructions : String) : Nil
      non_system = @messages.reject(&.role.system?)
      system_message = Message.new(role: Role::System, content: instructions)
      @messages = [system_message] + non_system
    end

    # ---- Callback dispatch -------------------------------------------------

    private def add_message_callback(name : String, &block : Message ->) : self
      (@callbacks[name] ||= [] of Message ->) << block
      self
    end

    private def run_message_callbacks(name : String, message : Message?) : Nil
      callbacks = @callbacks[name]?
      return unless callbacks
      callbacks.each { |callback| callback.call(message || Message.new(role: Role::Assistant)) }
    end

    private def run_tool_call_callbacks(tool_call : ToolCall) : Nil
      callbacks = @tool_call_callbacks["before_tool_call"]?
      return unless callbacks
      callbacks.each(&.call(tool_call))
    end

    private def run_tool_result_callbacks(result : ToolResult) : Nil
      callbacks = @tool_result_callbacks["after_tool_result"]?
      return unless callbacks
      callbacks.each(&.call(result))
    end
  end
end
