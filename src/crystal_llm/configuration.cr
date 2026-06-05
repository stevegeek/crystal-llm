# ported from lib/ruby_llm/configuration.rb @ ruby_llm 1.15.0
require "log"

module CrystalLLM
  # Global configuration for CrystalLLM.
  #
  # ruby_llm's dynamic `option` DSL (attr_accessor + a defaults hash applied in
  # `initialize`) collapses in Crystal: a typed `property` carries its own default,
  # so construction needs no defaults loop. Provider-specific options (api keys,
  # bases) are added by each provider file reopening this class with `option`.
  class Configuration
    # Each option is a typed `property` with its default. ruby_llm's `option` DSL
    # maps to plain `property` (Crystal carries the default natively). Provider
    # files reopen this class and add their api-key/base options the same way.

    # System-level options. Provider options live in each provider file.
    property default_model : String = "gpt-5.4"
    property default_embedding_model : String = "text-embedding-3-small"
    property default_moderation_model : String = "omni-moderation-latest"
    property default_image_model : String = "gpt-image-1.5"
    property default_transcription_model : String = "whisper-1"

    property model_registry_file : String = File.expand_path("models.json", __DIR__)
    property model_registry_class : String = "Model"
    property use_new_acts_as : Bool = false
    # ruby_llm's `model_registry_source` (an ActiveRecord source object) — typed
    # loosely until the model registry lands; the AR variant lives in crystal-llm-marten.
    property model_registry_source : String? = nil

    # The pluggable instrumentation sink (`nil` = no instrumentation, a transparent
    # no-op). Typed `Instrumenter?` rather than ruby_llm's untyped duck-typed slot.
    # The property is ADDED by `instrumentation.cr` reopening this class (the same
    # late-require pattern providers use for their api-key options), so the type is
    # known by the time it is referenced. See PORTING.md.

    property request_timeout : Int32 = 300
    property max_retries : Int32 = 3
    property retry_interval : Float64 = 0.1
    property retry_backoff_factor : Int32 = 2
    property retry_interval_randomness : Float64 = 0.5
    property http_proxy : String? = nil

    # Symbols-as-runtime-data become String here (design R5); becomes an enum when
    # deprecator.cr is ported.
    property deprecation_behavior : String = "warn"

    property logger : ::Log? = nil
    property log_file : IO = STDOUT
    property log_level : ::Log::Severity = (ENV["CRYSTAL_LLM_DEBUG"]? ? ::Log::Severity::Debug : ::Log::Severity::Info)
    property log_stream_debug : Bool = (ENV["CRYSTAL_LLM_STREAM_DEBUG"]? == "true")

    # The discoverable options API. Generated from the (final, post-reopen) set of
    # instance variables — instance_vars resolves in a method body, never a hook.
    # NOTE: every ivar on Configuration is by construction a public option, so do
    # NOT add a private/cache ivar here without filtering it out below.
    def self.options : Array(String)
      {{ @type.instance_vars.map(&.name.stringify) }}
    end

    # Reads a String-typed option by its runtime name — the Crystal analog of
    # ruby_llm's `@config.send(req)`. Providers query their api-key/base options
    # (all `String?`) this way for `configured?`/`ensure_configured!`. Returns nil
    # for an unknown key. Generated over the (post-reopen) String/String? ivars.
    def []?(key : String) : String?
      {% begin %}
        case key
        {% for ivar in @type.instance_vars %}
          {% if ivar.type.stringify == "String" || ivar.type.stringify == "(String | Nil)" %}
            when {{ ivar.name.stringify }} then @{{ ivar.name }}
          {% end %}
        {% end %}
        else nil
        end
      {% end %}
    end

    # True when the named option is present (non-nil) — provider configuration check.
    def configured?(key : String) : Bool
      !self[key]?.nil?
    end
  end
end
