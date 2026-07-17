# ported from lib/ruby_llm/instrumentation.rb @ ruby_llm 1.16.0
#
# Emits structured CrystalLLM events without requiring a specific observability
# backend. A host app can plug in any instrumenter (the Rails analogue is
# `ActiveSupport::Notifications`, wired via the railtie in ruby_llm — here it is
# wired by setting `CrystalLLM.config.instrumenter = ...`).
#
# == The Crystal seam (the one real divergence) ==
#
# ruby_llm leans on Ruby duck-typing: `instrumenter.respond_to?(:instrument)` and
# an event-payload `Hash` the block mutates (`event[:response] = ...`). Crystal
# has neither runtime `respond_to?` nor a heterogeneous-everything Hash, so this
# port reifies two things:
#
# * **`Instrumenter`** — an abstract base with a single
#   `instrument(name : String, payload : Payload, &block : Payload -> T) : T`
#   method. A host subclasses it (or uses the bundled `ProcInstrumenter`). This
#   replaces ruby_llm's `respond_to?(:instrument)` check: the *type* guarantees
#   the contract. `Configuration#instrumenter` is `Instrumenter?` (nil = no-op).
#
# * **`Payload`** — `Hash(String, Value)` where `Value` is the union of every
#   object actually placed in an event (Chat / Message / Tool / ToolCall / token
#   counts / option values / collections of those). ruby_llm's symbol keys become
#   String keys (symbols-as-runtime-data → String, design §11). The block receives
#   the *same* mutable payload hash so it can attach result keys (`response`,
#   `tool_calls`, token counts, …) exactly as ruby_llm's block does via `event`.
#
# == Behavioural parity ==
#
# `CrystalLLM.instrument(name, payload, config) { |event| ... }` (the module
# function, surfaced on the facade as `CrystalLLM.instrument`):
#
#   * builds nothing extra — the caller passes a fully-built `Payload` (ruby_llm's
#     `build_payload(payload, **attributes)` merge of keyword attributes has no
#     Crystal analogue without runtime kwargs; callers merge up-front instead — a
#     documented divergence, returned).
#   * resolves the instrumenter from the given config (or the global config).
#   * when there is NO instrumenter, it just `yield`s the payload (transparent
#     no-op) — same as ruby_llm's `return yield(payload) if ... && !instrumenter`.
#   * when an instrumenter IS present, it delegates to
#     `instrumenter.instrument(name, payload) { yield payload }`.
#
# The block is ALWAYS executed and its value returned, so wrapping a call in
# `instrument` never changes the call's result.
require "json"
require "./configuration"

module CrystalLLM
  # Reopen Configuration to add the (deferred-until-now) instrumenter slot — the
  # same late-require pattern providers use for their api-key options. `nil` means
  # no instrumentation.
  class Configuration
    property instrumenter : Instrumenter? = nil
  end

  module Instrumentation
    extend self

    # The value side of an event payload. The union mirrors the concrete objects
    # ruby_llm stuffs into the `chat.*` / `tool_call.*` payloads (see Chat). Kept
    # explicit (no `JSON::Any`-ification) so a host instrumenter receives the live
    # objects, not a lossy serialization.
    alias Value = String |
                  Int32 |
                  Int64 |
                  Float64 |
                  Bool |
                  Nil |
                  Symbol |
                  Chat |
                  Message |
                  Tool |
                  ToolCall |
                  Model::Info |
                  Thinking::Config |
                  JSON::Any |
                  Array(String) |
                  Array(Message) |
                  Hash(String, ToolCall) |
                  Hash(String, JSON::Any) |
                  ToolResult |
                  Provider.class

    # An event payload: a string-keyed bag of `Value`s. The block handed to
    # `instrument` may mutate it in place (the ruby_llm `event[:key] = ...` move).
    alias Payload = Hash(String, Value)

    # Emits `name` with `payload`, wrapping `block` in the configured instrumenter
    # (or running it transparently when none is configured). Returns the block's
    # value. Mirrors `RubyLLM.instrument`.
    def instrument(name : String, payload : Payload, config : Configuration? = nil, &block : Payload -> T) : T forall T
      instrumenter = instrumenter_for(config)
      if instrumenter
        instrumenter.instrument(name, payload) { |event| block.call(event) }
      else
        block.call(payload)
      end
    end

    # The instrumenter to use: the given config's, else the global config's.
    def instrumenter_for(config : Configuration?) : Instrumenter?
      (config || CrystalLLM.config).instrumenter
    end
  end

  # The pluggable instrumentation seam. A host subclasses this and wires an
  # instance via `CrystalLLM.config.instrumenter = MyInstrumenter.new`. The
  # contract: run `block` (which does the real work and returns the result),
  # observing `name` + `payload` around it. The default `nil` instrumenter means
  # "no instrumentation" — `Instrumentation.instrument` just yields.
  #
  # CRYSTAL DIVERGENCE: this is a *concrete* base (not `abstract`) whose default
  # `instrument` simply yields. Crystal cannot declare an `abstract def` whose
  # return type is a free `forall T` (the abstract signature can't resolve `T`), so
  # the contract is expressed as an overridable concrete method instead. Subclasses
  # override `instrument`; the default makes a bare `Instrumenter.new` a valid
  # (transparent) instrumenter too.
  class Instrumenter
    # Observe `name`/`payload` while running `block`, returning the block's value.
    # Overrides MUST call the block exactly once and return its result so
    # instrumentation never alters behaviour. The default just runs the block.
    def instrument(name : String, payload : Instrumentation::Payload,
                   &block : Instrumentation::Payload -> T) : T forall T
      block.call(payload)
    end
  end

  # A zero-ceremony `Instrumenter` backed by a callback Proc. The Proc receives
  # the event name and (post-block) payload AFTER the wrapped work runs, so it can
  # read result keys the block attached. Convenient for tests and simple sinks.
  #
  #   CrystalLLM.config.instrumenter = CrystalLLM::ProcInstrumenter.new do |name, payload|
  #     log.info { "#{name}: #{payload["model"]}" }
  #   end
  class ProcInstrumenter < Instrumenter
    def initialize(&callback : String, Instrumentation::Payload ->)
      @callback = callback
    end

    def instrument(name : String, payload : Instrumentation::Payload,
                   &block : Instrumentation::Payload -> T) : T forall T
      result = block.call(payload)
      @callback.call(name, payload)
      result
    end
  end
end
