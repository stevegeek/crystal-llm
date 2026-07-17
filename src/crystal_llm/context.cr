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

    # ---- Per-call entrypoints (mirror ruby_llm's Context#chat/embed/paint/…) ----
    #
    # Each forwards to the matching top-level operation with `context: self`, so the
    # operation resolves its config from this Context's (independent) copy. ruby_llm
    # forwards `*args, **kwargs`; the port spells out the same explicit parameters
    # the operations already accept. The referenced classes live across the shard;
    # Crystal resolves them at full-program build, so no extra `require` is needed.

    def chat(model : String? = nil, provider : String? = nil,
             assume_model_exists : Bool = false) : Chat
      Chat.new(model: model, provider: provider,
        assume_model_exists: assume_model_exists, context: self)
    end

    def embed(text : Provider::TextInput, model : String? = nil,
              provider : String? = nil, assume_model_exists : Bool = false,
              dimensions : Int32? = nil) : Embedding
      Embedding.embed(text, model: model, provider: provider,
        assume_model_exists: assume_model_exists, context: self, dimensions: dimensions)
    end

    def paint(prompt : String, model : String? = nil, provider : String? = nil,
              assume_model_exists : Bool = false, size : String = "1024x1024",
              with attachments : Attachable? = nil, mask : Source? = nil,
              params : Hash(String, JSON::Any) = {} of String => JSON::Any) : Image
      Image.paint(prompt, model: model, provider: provider,
        assume_model_exists: assume_model_exists, size: size, context: self,
        with: attachments, mask: mask, params: params)
    end

    def moderate(input : Provider::TextInput, model : String? = nil,
                 provider : String? = nil, assume_model_exists : Bool = false) : Moderation
      Moderation.moderate(input, model: model, provider: provider,
        assume_model_exists: assume_model_exists, context: self)
    end

    def transcribe(audio_file : String, model : String? = nil, language : String? = nil,
                   provider : String? = nil, assume_model_exists : Bool = false,
                   opts : Hash(String, JSON::Any) = {} of String => JSON::Any) : Transcription
      Transcription.transcribe(audio_file, model: model, language: language,
        provider: provider, assume_model_exists: assume_model_exists,
        context: self, opts: opts)
    end

    # Mirrors ruby_llm's `connection_for(provider_instance)` — exposes the
    # provider's (config-bound) connection.
    def connection_for(provider_instance : Provider) : Connection
      provider_instance.connection
    end
  end
end
