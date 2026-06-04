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
# == DEFERRED (returned) ==
#
# * **ERB / prompt files.** ruby_llm's `instructions` default (`{ prompt:
#   'instructions', locals: {} }`), `render_prompt`, `prompt_path_for`, ERB
#   rendering, and `ctx.prompt(name, **locals)` resolving a `*.txt.erb` file are
#   DEFERRED. `ctx.prompt` exists but takes a literal string and returns it
#   unchanged (a passthrough), so the ctx surface matches §8 without the
#   filesystem/ERB machinery. Use plain-string / block instructions instead.
# * **Rails/persistence hooks.** `chat_model`, `create`/`create!`, `find`,
#   `sync_instructions!`, `with_runtime_instructions`, `to_llm`,
#   `assume_model_exists` threading, and the `resolved_chat_model` const lookup
#   are persistence-layer concerns owned by the `crystal-llm-marten` companion
#   shard — DEFERRED here (design §10.7).
# * **Instrumentation.** No instrumentation hooks (matches chat.cr/facade.cr).
# * **`thinking` / `headers` / `schema` class macros.** ruby_llm's Agent also
#   carries `thinking`, `headers`, and `schema` (with block forms). They port
#   identically to `temperature`/`params` but are DEFERRED from this first cut to
#   keep the surface focused on the approved §8 example (model / instructions /
#   tools / temperature / params); add them the same way when needed.
# * **`Enumerable` + the full `def_delegators` list.** ruby_llm mixes in
#   `Enumerable` and delegates ~30 methods to `@chat`. This port delegates the
#   common conversation surface (`ask`, `say`, `messages`, `tools`, `model`,
#   `complete`, `add_message`, `reset_messages!`, `with_*` builders) via a
#   `method_missing` macro forwarding to `@chat`, subsuming the rest without
#   enumerating each.
require "json"
require "./chat"
require "./tool"
require "./context"
require "./facade"

module CrystalLLM
  # Base class for simple, class-configured agents. See the file header for the
  # explicit-context design and the list of deferrals.
  abstract class Agent
    # Per-subclass static configuration. Reset for every subclass by `macro
    # inherited` (Crystal class vars are per-subclass). The block forms are NOT
    # stored here — they generate `resolve_*` method overrides instead (see
    # header) — so these hold only the *static* values.
    @@agent_model : String? = nil
    @@agent_instructions : String? = nil
    @@agent_temperature : Float64? = nil
    @@agent_params : Hash(String, JSON::Any)? = nil

    macro inherited
      @@agent_model = nil
      @@agent_instructions = nil
      @@agent_temperature = nil
      @@agent_params = nil

      # Per-subclass list of declared inputs: [{name, Type}, …]. Consumed by the
      # `macro finished` hook to emit the typed Context + constructor.
      AGENT_INPUTS = [] of Nil

      # ---- Class-level DSL ---------------------------------------------------

      # Sets the chat model id (a `String`; ruby_llm also accepts `**options`
      # forwarded to `RubyLLM.chat`, deferred here to the model id).
      def self.model(model_id : String) : Nil
        @@agent_model = model_id
      end

      def self.model : String?
        @@agent_model
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

      # Static form of `tools`: `tools T1.new, T2.new`. Stored as a (per-subclass)
      # instance-side override so the static + block paths share `resolve_tools`.
      # ruby_llm accepts tool *classes* and instantiates them; Crystal cannot
      # `.new` an arbitrary `Tool.class` (no shared zero-arg ctor contract — same
      # divergence as `Chat#with_tool`), so callers pass instances.
      macro tools(*tool_instances)
        def resolve_tools(ctx : Context) : Array(CrystalLLM::Tool)
          [\{{ tool_instances.splat }}] of CrystalLLM::Tool
        end
      end

      # `input name : Type` — record the input for the generated Context + ctor.
      macro input(decl)
        \{% AGENT_INPUTS << {decl.var, decl.type} %}
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
        [] of CrystalLLM::Tool
      end

      # Applies the resolved configuration onto `@chat` (mirrors ruby_llm's
      # `apply_configuration` → `apply_instructions`/`apply_tools`/… sequence).
      private def apply_configuration(ctx : Context) : Nil
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

          # DEFERRED: ERB prompt-file rendering. Returns the name unchanged so
          # the ctx surface matches §8 without the filesystem/ERB machinery.
          def prompt(name : String) : String
            name
          end
        end

        # Builds the Chat, the Context, resolves config against it, and applies it.
        def initialize(
          \{% for pair in AGENT_INPUTS %}
            \{{ pair[0] }} : \{{ pair[1] }},
          \{% end %}
        )
          # Build the base Chat from the static model config (mirrors
          # `RubyLLM.chat(**chat_kwargs)`). `model` is the per-subclass class
          # method declared in `macro inherited`.
          @chat = CrystalLLM.chat(model: self.class.model)
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
    def ask(message : String? = nil) : CrystalLLM::Message
      @chat.ask(message)
    end

    macro method_missing(call)
      @chat.{{ call }}
    end
  end
end
