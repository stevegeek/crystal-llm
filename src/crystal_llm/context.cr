# ported from lib/ruby_llm/context.rb @ ruby_llm 1.15.0
require "./configuration"

module CrystalLLM
  # Holds a per-call configuration. A Context wraps an independent copy of the
  # global configuration so callers can override settings (model, api keys, …)
  # for a scoped set of operations without mutating the global config.
  #
  # In ruby_llm the dup-and-yield lives in `RubyLLM.context { |config| … }`
  # (lib/ruby_llm.rb). That top-level entry point is `src/crystal_llm.cr` here,
  # which adds `CrystalLLM.context`. The copy/override mechanics themselves are
  # owned by this class via `Context.create`, so the behaviour is exercised in
  # isolation and the entry point just delegates.
  class Context
    getter config : Configuration

    def initialize(@config : Configuration)
    end

    # Builds a Context over an independent copy of `config`, applying the block
    # to that copy first. Mirrors ruby_llm's `config.dup; yield; Context.new`.
    #
    # `Configuration` holds only value-type options (Strings/Numbers/Bool) plus
    # shared IO/Log references, so a shallow `dup` is the correct analog of
    # Ruby's `config.dup` (which is likewise shallow): overriding a property on
    # the copy never touches the original.
    def self.create(config : Configuration, & : Configuration ->) : Context
      context_config = config.dup
      yield context_config
      new(context_config)
    end

    # No-block variant: a Context over a plain copy of `config`.
    def self.create(config : Configuration) : Context
      new(config.dup)
    end

    # DEFERRED — per-call entrypoints. ruby_llm's Context exposes `chat`, `embed`,
    # `paint`, and `connection_for`, each forwarding to a not-yet-ported class
    # (Chat / Embedding / Image / Provider). These are omitted until those
    # dependencies land; the config-copy behaviour above is the portable core.
    # Tracked in `deferrals`.
  end
end
