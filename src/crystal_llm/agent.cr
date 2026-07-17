# ported from lib/ruby_llm/agent.rb @ ruby_llm 1.15.0
#
# Base class for class-configured agents. A subclass declares its model,
# instructions, tools, temperature, and params at the class level; `Agent.new`
# builds a `Chat`, applies the (resolved) configuration, and delegates the chat
# API (`ask`, `say`, `messages`, …) to it.
#
# == The central Crystal divergence: explicit-context, typed `input` (design §8) ==
#
# ruby_llm's runtime-context form evaluates `instructions`/`tools`/`params`
# blocks with `instance_exec` against a *synthesized* receiver (an `Object.new`
# with `define_singleton_method` accessors for each input + `chat`/`prompt`).
# Crystal has no `instance_exec`, no `define_singleton_method`, and no runtime
# method synthesis, so the port uses **explicit `ctx` blocks + a typed `input`
# macro**:
#
#   class WorkAssistant < CrystalLLM::Agent
#     model "gpt-4o"
#     input user : String                                # typed accessor on ctx
#     instructions { |ctx| "You are helping #{ctx.user}" }
#     tools        { |ctx| [TodoTool.new] of CrystalLLM::Tool }
#     temperature 0.2
#     params({"max_output_tokens" => JSON::Any.new(256_i64)})
#   end
#
#   WorkAssistant.new(user: "Sam").ask("…")
#
# `input name : Type` (1) records the input on a per-subclass list and (2) makes
# the generated per-subclass `Context` expose a typed `ctx.name` getter. The
# Context also exposes `chat` (the built Chat) and `prompt` (see prompt note).
# Static forms — `instructions "..."`, `tools T1, T2` — coexist with the block
# forms; the block, when given, wins.
#
# == How the per-subclass state is realised ==
#
# Each subclass gets its own accumulators. ruby_llm uses `self.inherited` to dup
# the parent's ivars; here `macro inherited` resets per-subclass class vars
# (Crystal class vars are per-subclass — verified, same pattern as tool.cr's
# `@@parameters`). The typed Context class + the typed `initialize` are emitted
# in a `macro finished` hook, after the subclass body (and therefore all `input`
# declarations) has been parsed.
#
# Block storage: `instructions`/`tools` blocks reference the subclass-specific
# `Context`, so they cannot live in a base-class-typed class var. Instead the
# block macros *generate method overrides* (`resolve_instructions(ctx)` /
# `resolve_tools(ctx)`) on the subclass; the default implementations read the
# static class vars. This keeps the block body fully typed against `Context`.
#
# == Prompt templates: ECR instead of runtime ERB ==
#
# ruby_llm's prompt files are ERB templates discovered + read at RUNTIME by
# convention (`app/prompts/<agent>/<name>.txt.erb`) and rendered with
# `instance_exec` so the template sees the agent's inputs/`chat`/`prompt`. Crystal
# has no runtime ERB or `instance_exec`, but **ECR** (Embedded Crystal,
# `<%= … %>`) is the native, type-safe analog — so this is ported via ECR rather
# than deferred:
#
#   prompt_template "greeting", "#{__DIR__}/prompts/greeting.ecr"  # explicit path
#   prompt_template "instructions"                                 # path INFERRED
#   instructions(&.prompt("instructions"))                         # renders it
#
# The PATH is optional: omit it and it is inferred by convention —
# `"#{__DIR__}/prompts/<class_snake_path>/<name>.ecr"` rooted at the agent's own
# source dir (the Crystal/ECR analog of ruby_llm's project-root
# `app/prompts/<class>/<name>.txt.erb`; `MyApp::WorkAssistant` →
# `prompts/my_app/work_assistant/<name>.ecr`).
#
# The template is embedded at COMPILE time and rendered in the Context's scope, so
# `<%= user %>` resolves to the typed `input` getter `ctx.user` (the inputs-as-
# locals are type-checked — stricter than ruby_llm). Divergences from ruby_llm:
# (1) the path resolves at COMPILE time (literal or inferred-by-convention) and the
# template ships in the binary, vs ruby_llm's runtime file discovery — a missing
# file fails the build, not a runtime `PromptNotFoundError`; (2) arbitrary
# `**locals` beyond the declared `input`s are not threaded (declare an `input`).
# An undeclared `ctx.prompt(name)` still returns `name` unchanged (passthrough).
#
# == DEFERRED (returned) ==
# * **Persistence hooks** (`chat_model`, `create`/`create!`, `find`,
#   `sync_instructions!`, `with_runtime_instructions`, `to_llm`, the
#   `resolved_chat_model` const lookup) bind an Agent subclass to a database-backed
#   Chat record. They are owned by the `crystal-llm-marten` companion shard's
#   `acts_as_agent` macro (which calls the static-config accessors added here:
#   `model`/`agent_provider`/`agent_assume_model_exists`/`instructions`/
#   `tools_list`/`temperature`/`params`/`headers`/`thinking`/`schema`/`context`).
#   Core stays persistence-agnostic. Runtime-input *blocks* against a persisted
#   record (ruby_llm's `instance_exec` runtime context) remain DEFERRED — the
#   binding applies the STATIC configuration, matching the common case.
# * **Instrumentation.** No instrumentation hooks (matches chat.cr/facade.cr).
# * **`Enumerable` + the full `def_delegators` list.** ruby_llm mixes in
#   `Enumerable` and delegates ~30 methods to `@chat`. This port delegates the
#   common conversation surface (`ask`, `say`, `messages`, `tools`, `model`,
#   `complete`, `add_message`, `reset_messages!`, `with_*` builders) via a
#   `method_missing` macro forwarding to `@chat`, subsuming the rest without
#   enumerating each.
require "json"
require "ecr"
require "./chat"
require "./tool"
require "./context"
require "./schema"
require "./thinking"
require "./facade"

module CrystalLLM
  # The shapes a static/block agent `schema` may hold — exactly `Chat#with_schema`'s
  # accepted argument types (a `Schema` instance, a raw json-schema `Hash`, or a
  # `JSON::Any`). Aliased to keep the per-subclass `resolve_schema` signatures on
  # one line (a backslash line-continuation inside the `schema` macro is mangled
  # by the formatter).
  alias AgentSchemaValue = CrystalLLM::Schema | Hash(String, JSON::Any) | JSON::Any

  # Base class for simple, class-configured agents. See the file header for the
  # explicit-context design and the list of deferrals.
  abstract class Agent
    # Per-subclass static configuration. Reset for every subclass by `macro
    # inherited` (Crystal class vars are per-subclass). The block forms are NOT
    # stored here — they generate `resolve_*` method overrides instead (see
    # header) — so these hold only the *static* values.
    @@agent_model : String? = nil
    # Optional provider slug + assume-model-exists flag forwarded alongside the
    # model id (ruby_llm's `model(model_id, **options)` passes both through to
    # `RubyLLM.chat`). Carried here so a `chat_model`-bound persisted record can be
    # wired to a specific provider without a registry lookup.
    @@agent_provider : String? = nil
    @@agent_assume_model_exists : Bool = false
    @@agent_instructions : String? = nil
    @@agent_temperature : Float64? = nil
    @@agent_params : Hash(String, JSON::Any)? = nil
    @@agent_headers : Hash(String, String)? = nil
    @@agent_thinking : CrystalLLM::Thinking::Config? = nil
    # A static schema is held as one of `with_schema`'s accepted shapes: a
    # `Schema` instance, a raw json-schema `Hash`, or a `JSON::Any`. (ruby_llm
    # accepts a Schema *class*; Crystal can't `.new` an arbitrary subclass with a
    # shared contract — the same divergence as `tools` — so callers pass an
    # instance.)
    @@agent_schema : CrystalLLM::AgentSchemaValue? = nil
    # A static config Context (`CrystalLLM::Context`) re-bound onto the Chat via
    # `with_context`. Distinct from the per-subclass runtime `Context` used by the
    # `instructions`/`tools`/`schema` blocks — referenced fully-qualified to avoid
    # the name clash.
    @@agent_context : CrystalLLM::Context? = nil
    # The static-tools list (set by the `tools T1.new, T2.new` form). Held at the
    # class level — not only as a `resolve_tools` override — so the persistence
    # binding (`crystal-llm-marten`'s `acts_as_agent`) can read the configured
    # tools without an instance/ctx. Block-form tools (`tools { |ctx| ... }`)
    # override `resolve_tools` instead and leave this nil.
    @@agent_static_tools : Array(CrystalLLM::Tool)? = nil

    macro inherited
      @@agent_model = nil
      @@agent_provider = nil
      @@agent_assume_model_exists = false
      @@agent_instructions = nil
      @@agent_temperature = nil
      @@agent_params = nil
      @@agent_headers = nil
      @@agent_thinking = nil
      @@agent_schema = nil
      @@agent_context = nil
      @@agent_static_tools = nil

      # Per-subclass list of declared inputs: [{name, Type}, …]. Consumed by the
      # `macro finished` hook to emit the typed Context + constructor.
      AGENT_INPUTS = [] of Nil

      # Per-subclass list of declared ECR prompt templates: [{name, path}, …].
      # Consumed by `macro finished` to emit the Context's `prompt(name)` dispatch.
      PROMPT_TEMPLATES = [] of Nil

      # ---- Class-level DSL ---------------------------------------------------

      # Sets the chat model id. ruby_llm's `model(model_id, **options)` forwards
      # arbitrary options to `RubyLLM.chat`; this port surfaces the two that matter
      # for model resolution — `provider` (pin the provider slug) and
      # `assume_model_exists` (skip the registry lookup). Both default to the
      # registry-driven behaviour.
      def self.model(model_id : String, provider : String? = nil,
                     assume_model_exists : Bool = false) : Nil
        @@agent_model = model_id
        @@agent_provider = provider
        @@agent_assume_model_exists = assume_model_exists
      end

      def self.model : String?
        @@agent_model
      end

      def self.agent_provider : String?
        @@agent_provider
      end

      def self.agent_assume_model_exists : Bool
        @@agent_assume_model_exists
      end

      # Static instructions. The block form is `instructions { |ctx| ... }`
      # (a macro, defined below), which overrides `resolve_instructions`.
      def self.instructions(text : String) : Nil
        @@agent_instructions = text
      end

      def self.instructions : String?
        @@agent_instructions
      end

      def self.temperature(value : Float64) : Nil
        @@agent_temperature = value
      end

      def self.temperature : Float64?
        @@agent_temperature
      end

      # Static params merged over the provider payload (ruby_llm's `with_params`
      # is replace-not-merge — preserved). Block form: `params { |ctx| {...} }`.
      def self.params(value : Hash(String, JSON::Any)) : Nil
        @@agent_params = value
      end

      def self.params : Hash(String, JSON::Any)?
        @@agent_params
      end

      # Static request headers merged onto the Chat via `with_headers` (which is
      # replace-not-merge — preserved). Block form: `headers { |ctx| {...} }`.
      def self.headers(value : Hash(String, String)) : Nil
        @@agent_headers = value
      end

      def self.headers : Hash(String, String)?
        @@agent_headers
      end

      # Enables thinking on the built Chat. Mirrors ruby_llm's dual-purpose
      # `thinking(effort:, budget:)`: with no args it reads the configured
      # `Thinking::Config`; with `effort`/`budget` it sets one. (`effort` is a
      # String — symbols-as-runtime-data → String, §11.) Kept as a single method
      # because both args are optional: a separate zero-arg getter would collide
      # with the no-arg setter call (unlike `temperature`/`headers`, whose setters
      # take a required arg and so don't clash with their getters).
      def self.thinking(effort : String? = nil, budget : Int32? = nil) : CrystalLLM::Thinking::Config?
        return @@agent_thinking if effort.nil? && budget.nil?

        @@agent_thinking = CrystalLLM::Thinking::Config.new(effort: effort, budget: budget)
      end

      # Static structured-output schema. Accepts a `Schema` instance, a raw
      # json-schema `Hash`, or a `JSON::Any` (all `with_schema` shapes). Block
      # form: `schema { |ctx| ... }` (a macro below), which overrides
      # `resolve_schema`.
      def self.schema(value : CrystalLLM::AgentSchemaValue) : Nil
        @@agent_schema = value
      end

      def self.schema : CrystalLLM::AgentSchemaValue?
        @@agent_schema
      end

      # Static config Context re-bound onto the Chat via `with_context`.
      def self.context(value : CrystalLLM::Context) : Nil
        @@agent_context = value
      end

      def self.context : CrystalLLM::Context?
        @@agent_context
      end

      # Block form of `instructions`: `instructions { |ctx| "...#{ctx.foo}" }`.
      # Generates a `resolve_instructions(ctx)` override returning the block's
      # value. The block is typed against the per-subclass `Context`.
      macro instructions(&block)
        \{% if block.args.size != 1 %}
          \{% raise "instructions block must take exactly one arg (the ctx): instructions { |ctx| ... }" %}
        \{% end %}
        def resolve_instructions(\{{ block.args.first }} : Context) : String?
          \{{ block.body }}
        end
      end

      # Block form of `tools`: `tools { |ctx| [T.new(...)] of CrystalLLM::Tool }`.
      # Generates a `resolve_tools(ctx)` override returning the tool array.
      macro tools(&block)
        \{% if block.args.size != 1 %}
          \{% raise "tools block must take exactly one arg (the ctx): tools { |ctx| ... }" %}
        \{% end %}
        def resolve_tools(\{{ block.args.first }} : Context) : Array(CrystalLLM::Tool)
          \{{ block.body }}
        end
      end

      # Block form of `headers`: `headers { |ctx| {"x" => ctx.foo} }`. Generates a
      # `resolve_headers(ctx)` override; the block body is typed against `Context`.
      macro headers(&block)
        \{% if block.args.size != 1 %}
          \{% raise "headers block must take exactly one arg (the ctx): headers { |ctx| ... }" %}
        \{% end %}
        def resolve_headers(\{{ block.args.first }} : Context) : Hash(String, String)?
          \{{ block.body }}
        end
      end

      # Block form of `schema`: `schema { |ctx| MySchema.new(ctx.kind) }`. Generates
      # a `resolve_schema(ctx)` override returning any `with_schema` shape (a
      # `Schema` instance / json-schema `Hash` / `JSON::Any`), typed against
      # `Context`. (ruby_llm also treats a NoMethodError-on-ctx block as a
      # `Schema.create(&block)` DSL; `Schema.create` is dropped in this port — see
      # schema.cr — so the block here must return a value, not a bare DSL body.)
      macro schema(&block)
        \{% if block.args.size != 1 %}
          \{% raise "schema block must take exactly one arg (the ctx): schema { |ctx| ... }" %}
        \{% end %}
        def resolve_schema(\{{ block.args.first }} : Context) : CrystalLLM::AgentSchemaValue?
          \{{ block.body }}
        end
      end

      # Static form of `tools`: `tools T1.new, T2.new`. Records the instances in the
      # per-subclass `@@agent_static_tools` class var, which the default
      # `resolve_tools` reads — so the static + block paths share `resolve_tools`
      # AND the configured tools are reachable at the class level (via `tools_list`)
      # for the persistence binding. ruby_llm accepts tool *classes* and
      # instantiates them; Crystal cannot `.new` an arbitrary `Tool.class` (no
      # shared zero-arg ctor contract — same divergence as `Chat#with_tool`), so
      # callers pass instances.
      macro tools(*tool_instances)
        @@agent_static_tools = [\{{ tool_instances.splat }}] of CrystalLLM::Tool
      end

      # The class-level static-tools accessor. Returns the `tools T1.new, …` list,
      # or an empty array when none were declared (or the block form was used).
      def self.tools_list : Array(CrystalLLM::Tool)
        @@agent_static_tools || [] of CrystalLLM::Tool
      end

      # `input name : Type` — record the input for the generated Context + ctor.
      macro input(decl)
        \{% AGENT_INPUTS << {decl.var, decl.type} %}
      end

      # `prompt_template "name"[, "#{__DIR__}/path.ecr"]` — declare an ECR template
      # the Context renders via `ctx.prompt("name")`. The template is embedded at
      # COMPILE time and rendered in the Context's scope, so the agent's typed
      # `input`s are available as bare names — `<%= user %>` calls `ctx.user`
      # (type-safe; arbitrary `**locals` are not threaded — declare an `input`).
      #
      # The PATH is OPTIONAL. Omit it and the path is INFERRED by convention, the
      # Crystal/ECR analog of ruby_llm's `app/prompts/<class_path>/<name>.txt.erb`:
      #
      #     "#{__DIR__}/prompts/<class_snake_path>/<name>.ecr"
      #
      # rooted at the AGENT'S OWN source directory (not a project root — ECR is
      # compile-time + source-relative) with `<class_snake_path>` the snake_case'd
      # class name (`MyApp::WorkAssistant` → `my_app/work_assistant`). So
      # `prompt_template "instructions"` on `WorkAssistant` reads
      # `<agent_dir>/prompts/work_assistant/instructions.ecr`. (A missing file fails
      # at COMPILE time — stricter than ruby_llm's runtime `PromptNotFoundError`.)
      # Pass an explicit path to override the convention.
      macro prompt_template(name, path = nil)
        \{% PROMPT_TEMPLATES << {name, path} %}
      end

      # The built Chat. Declared per-subclass (with the getter) because the
      # generated `initialize` — which assigns `@chat` — is also per-subclass;
      # declaring it on the abstract base (which has no initializer) trips
      # Crystal's "not initialized in all initialize methods" check.
      getter chat : CrystalLLM::Chat

      # ---- Resolution hooks (default impls; block macros override) ------------
      #
      # These reference the per-subclass `Context`, so they live here (not on the
      # base `Agent`, which has no `Context`). `Context` is generated by `macro
      # finished`; method *bodies*/*signatures* are only typechecked later, so
      # referencing it now is fine. A `instructions { |ctx| ... }` / `tools { ...
      # }` / `tools T.new` macro redefines the matching method (last def wins).
      def resolve_instructions(ctx : Context) : String?
        self.class.instructions
      end

      def resolve_tools(ctx : Context) : Array(CrystalLLM::Tool)
        self.class.tools_list
      end

      def resolve_headers(ctx : Context) : Hash(String, String)?
        self.class.headers
      end

      def resolve_schema(ctx : Context) : CrystalLLM::AgentSchemaValue?
        self.class.schema
      end

      # Applies the resolved configuration onto `@chat` (mirrors ruby_llm's
      # `apply_configuration` → `apply_instructions`/`apply_tools`/… sequence).
      private def apply_configuration(ctx : Context) : Nil
        # Context first (ruby_llm order): `with_context` re-binds the provider, so
        # it must run before the value-setting builders below.
        if context = self.class.context
          @chat.with_context(context)
        end

        if instr = resolve_instructions(ctx)
          @chat.with_instructions(instr)
        end

        resolve_tools(ctx).each { |tool| @chat.with_tool(tool) }

        if temp = self.class.temperature
          @chat.with_temperature(temp)
        end

        if prm = self.class.params
          @chat.with_params(prm) unless prm.empty?
        end

        if hdrs = resolve_headers(ctx)
          @chat.with_headers(hdrs) unless hdrs.empty?
        end

        if thinking = self.class.thinking
          @chat.with_thinking(effort: thinking.effort, budget: thinking.budget)
        end

        if sch = resolve_schema(ctx)
          @chat.with_schema(sch)
        end
      end

      # Emitted after the subclass body is fully parsed: the typed `Context`
      # (built-in `chat`/`prompt` + a typed getter per declared `input`) and the
      # typed `initialize` (one kwarg per input).
      macro finished
        # The runtime context passed to `instructions`/`tools` blocks. `chat` is
        # the built Chat; `prompt` is a passthrough (ERB deferred — see header).
        class Context
          getter chat : CrystalLLM::Chat

          \{% for pair in AGENT_INPUTS %}
            getter \{{ pair[0] }} : \{{ pair[1] }}
          \{% end %}

          def initialize(
            @chat : CrystalLLM::Chat,
            \{% for pair in AGENT_INPUTS %}
              @\{{ pair[0] }} : \{{ pair[1] }},
            \{% end %}
          )
          end

          # Renders a declared ECR prompt template by name (ruby_llm's
          # `ctx.prompt(name)`). Each `prompt_template "name", path` declared on the
          # agent becomes a `when` branch that `ECR.render`s the template IN THIS
          # CONTEXT'S SCOPE — so the template's `<%= user %>` resolves to the typed
          # `input` getter `ctx.user`. The template is compile-time-embedded (the
          # Crystal analog of ruby_llm's runtime `*.txt.erb`). An undeclared name
          # falls through to itself (the prior passthrough behaviour), so a literal
          # string still works.
          def prompt(name : String) : String
            \{% begin %}
              # The agent's snake_case class path (`MyApp::WorkAssistant` →
              # `my_app/work_assistant`), for convention-inferred template paths.
              # `@type` here is the agent class (this `\{%  %}` runs at `finished`
              # expansion in the subclass's scope), so it is the AGENT, not Context.
              \{% snake = @type.name(generic_args: false).gsub(/::/, "/").underscore %}
              case name
              \{% for tmpl in PROMPT_TEMPLATES %}
                \{% if tmpl[1] == nil %}
                  # Inferred: "#{__DIR__}/prompts/<class_snake>/<name>.ecr" relative
                  # to the agent's own source dir (emitted `__DIR__` resolves there).
                  when \{{ tmpl[0] }} then ECR.render("#{__DIR__}/prompts/\{{ snake.id }}/\{{ tmpl[0].id }}.ecr")
                \{% else %}
                  when \{{ tmpl[0] }} then ECR.render(\{{ tmpl[1] }})
                \{% end %}
              \{% end %}
              else name
              end
            \{% end %}
          end
        end

        # Builds the Chat, the Context, resolves config against it, and applies it.
        def initialize(
          \{% for pair in AGENT_INPUTS %}
            \{{ pair[0] }} : \{{ pair[1] }},
          \{% end %}
        )
          # Build the base Chat from the static model config (mirrors
          # `RubyLLM.chat(**chat_kwargs)`). `model`/`agent_provider`/
          # `agent_assume_model_exists` are the per-subclass class methods declared
          # in `macro inherited`.
          @chat = CrystalLLM.chat(
            model: self.class.model,
            provider: self.class.agent_provider,
            assume_model_exists: self.class.agent_assume_model_exists,
          )
          ctx = Context.new(
            @chat,
            \{% for pair in AGENT_INPUTS %}
              \{{ pair[0] }},
            \{% end %}
          )
          apply_configuration(ctx)
        end
      end
    end

    # ---- Delegation ----------------------------------------------------------
    #
    # ruby_llm mixes in `Enumerable` + `def_delegators :chat, …` (~30 methods).
    # A `method_missing` macro forwards the whole conversation surface to `@chat`
    # in one shot (say/messages/tools/model/complete/with_*/…), subsuming the
    # explicit delegator list. `ask` is spelled out so its typed return
    # (`CrystalLLM::Message`) and default arg are visible / inspectable.
    def ask(message : String? = nil) : CrystalLLM::Message | CrystalLLM::Tool::Halt
      @chat.ask(message)
    end

    # `method_missing` cannot forward a block or carry the `with:` attachment kwarg
    # through (Crystal's macro `method_missing` only captures positional/named args,
    # not a passed block). ruby_llm's `def_delegators` forwards both, so these
    # explicit overloads delegate the block + attachment surface to `@chat`.

    def ask(message : String? = nil, with attachments : CrystalLLM::Attachable? = nil) : CrystalLLM::Message | CrystalLLM::Tool::Halt
      @chat.ask(message, with: attachments)
    end

    def ask(message : String? = nil, with attachments : CrystalLLM::Attachable? = nil,
            &block : CrystalLLM::Chunk ->) : CrystalLLM::Message | CrystalLLM::Tool::Halt
      @chat.ask(message, with: attachments, &block)
    end

    def say(message : String? = nil, with attachments : CrystalLLM::Attachable? = nil) : CrystalLLM::Message | CrystalLLM::Tool::Halt
      @chat.say(message, with: attachments)
    end

    def say(message : String? = nil, with attachments : CrystalLLM::Attachable? = nil,
            &block : CrystalLLM::Chunk ->) : CrystalLLM::Message | CrystalLLM::Tool::Halt
      @chat.say(message, with: attachments, &block)
    end

    def each(&block : CrystalLLM::Message ->) : Nil
      @chat.each(&block)
    end

    def complete(&block : CrystalLLM::Chunk ->) : CrystalLLM::Message | CrystalLLM::Tool::Halt
      @chat.complete(&block)
    end

    macro method_missing(call)
      @chat.{{ call }}
    end
  end
end
