# ported from lib/ruby_llm.rb @ ruby_llm 1.15.0
#
# The top-level `CrystalLLM` facade: the `class << self` entry points from
# ruby_llm.rb (`chat`, `models`, `providers`, `context`). This reopens the
# `CrystalLLM` module rather than living in `src/crystal_llm.cr` so the facade
# can be ported/specced in isolation; `config`/`configure`/`logger` already live
# in `src/crystal_llm.cr` and are NOT re-defined here.
#
# == Divergences from ruby_llm (documented + returned) ==
#
# * `chat(...)` — ruby_llm forwards `(...)` opaquely to `Chat.new`. Crystal has no
#   `...` arg-forwarding, so the four keyword parameters are spelled out
#   explicitly and forwarded by name. The names + defaults mirror `Chat#initialize`
#   (`model`, `provider`, `assume_model_exists`, `context`). `model`/`provider`
#   are `String?` (ruby_llm passes a Symbol-or-String model id / provider; per
#   design §11 symbols-as-runtime-data become `String`).
#
# * `models` — ruby_llm returns `Models.instance` (the singleton registry object,
#   which is Enumerable over Model::Info). This port returns the same singleton
#   instance via `Models.instance`. The instance *is* the registry.
#
# * `providers` — ruby_llm returns `Provider.providers.values` where the registry
#   is a `Hash(Symbol, Class)`. Here the registry is `Hash(String, Provider.class)`
#   (symbols-as-runtime-data → String, design §11), so `.values` is
#   `Array(Provider.class)`.
#
# * `context(&)` — ruby_llm dups `config`, yields it, and wraps it in a
#   `Context.new`. That copy/yield/wrap mechanic is owned by `Context.create`
#   (see context.cr), so this delegates with an explicit block (Crystal has no
#   implicit `block_given?`). A no-block variant is also provided to mirror
#   ruby_llm's `yield ... if block_given?`.
#
# == DEFERRED (returned) ==
#
# The following ruby_llm.rb class methods are NOT ported here because the
# provider-side methods they call have not been ported yet (per task scope):
#
# * `embed(...)`      → `Embedding.embed` — needs the embeddings provider methods.
# * `paint(...)`      → `Image.paint` — needs the image-generation provider methods.
# * `transcribe(...)` → `Transcription.transcribe` — needs the transcription
#                       provider methods.
# * `moderate(...)`   → `Moderation.moderate` — needs the moderation provider methods.
#
# Also deferred (not facade-shaped, belong to later ports):
# * `instrument(...)` / `deprecator` — instrumentation + deprecator plumbing.
# * The `Provider.register :anthropic, ...` (etc.) registration block at the bottom
#   of ruby_llm.rb — each provider file self-registers at require time (see e.g.
#   `providers/openai.cr`'s trailing `Provider.register("openai", ...)`).
require "./chat"
require "./models"
require "./provider"
require "./context"
require "./configuration"

module CrystalLLM
  # Starts a new chat conversation. Mirrors `RubyLLM.chat`.
  #
  # Resolves *model* against the registry and instantiates its provider; does no
  # network I/O. Defaults mirror `Chat#initialize`.
  def self.chat(model : String? = nil, provider : String? = nil,
                assume_model_exists : Bool = false, context : Context? = nil) : Chat
    Chat.new(
      model: model,
      provider: provider,
      assume_model_exists: assume_model_exists,
      context: context,
    )
  end

  # The model registry (the singleton `Models` instance, Enumerable over
  # `Model::Info`). Mirrors `RubyLLM.models`.
  def self.models : Models
    Models.instance
  end

  # All registered provider classes. Mirrors `RubyLLM.providers`
  # (`Provider.providers.values`).
  def self.providers : Array(Provider.class)
    Provider.providers.values
  end

  # Builds a scoped Context over an independent copy of the global config,
  # applying the block to that copy first. Mirrors `RubyLLM.context { |c| ... }`.
  def self.context(& : Configuration ->) : Context
    Context.create(config) { |cfg| yield cfg }
  end

  # No-block variant — a Context over a plain copy of the global config (mirrors
  # ruby_llm's `yield ... if block_given?`, where the block is optional).
  def self.context : Context
    Context.create(config)
  end
end
