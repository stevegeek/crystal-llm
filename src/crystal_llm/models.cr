# ported from lib/ruby_llm/models.rb @ ruby_llm 1.15.0
require "json"
require "./error"
require "./model/info"

module CrystalLLM
  # Manages model aliases for provider-specific versions.
  #
  # In ruby_llm this is lib/ruby_llm/aliases.rb — it lives here because it is
  # only consumed by Models. If it grows callers, extract to aliases.cr.
  #
  # Divergences: loaded at compile time via `{{ read_file(...) }}` macro so the
  # data is baked into the binary (no runtime file I/O). ruby_llm reads it lazily
  # at runtime from disk.
  class Aliases
    # Alias map: alias_id -> { provider -> concrete_id }
    ALIASES_JSON = {{ read_file("#{__DIR__}/aliases.json") }}

    @@data : Hash(String, Hash(String, String))? = nil

    # Returns the parsed alias map (memoized).
    def self.data : Hash(String, Hash(String, String))
      @@data ||= parse_aliases
    end

    # Resolves *model_id* to a concrete id for the given *provider*.
    # If the alias has no entry for the given provider, returns *model_id* unchanged.
    # If *provider* is nil, returns the first alias value (ruby_llm parity).
    def self.resolve(model_id : String, provider : String? = nil) : String
      entry = data[model_id]?
      return model_id unless entry

      if prov = provider
        entry[prov]? || model_id
      else
        entry.values.first? || model_id
      end
    end

    private def self.parse_aliases : Hash(String, Hash(String, String))
      outer = Hash(String, Hash(String, String)).new
      parsed = JSON.parse(ALIASES_JSON)
      parsed.as_h.each do |alias_key, providers_any|
        inner = Hash(String, String).new
        providers_any.as_h.each do |prov, concrete_any|
          inner[prov] = concrete_any.as_s
        end
        outer[alias_key] = inner
      end
      outer
    end
  end

  # Registry of available AI models and their capabilities.
  #
  # Enumerable over Model::Info — supports `select`, `map`, `each`, etc.
  #
  # DEFERRED (from ruby_llm):
  # - `refresh!`   — hits models.dev over the network; network I/O belongs in a
  #                  separate layer and depends on Connection/HTTP which is not yet
  #                  ported. Raises NotImplementedError as a stub.
  # - `save_to_json` — writes the registry back to disk; not meaningful for a
  #                    compile-time-embedded registry. Will make sense once
  #                    `refresh!` lands and we have mutable in-process state.
  # - `load_from_database!` — ActiveRecord; belongs in crystal-llm-marten.
  # - `resolve` provider-instance half — ruby_llm's `resolve` returns
  #   `[Model::Info, ProviderInstance]`. This port returns just `Model::Info`
  #   until Provider can be instantiated with a live Configuration. Callers that
  #   need the provider instance should call `Provider.resolve(model.provider)`.
  #
  # Divergences:
  # - Models data is embedded at **compile time** via the `read_file` macro —
  #   there is no runtime JSON file read. This matches the shard distribution
  #   story (binary carries its own registry).
  # - Class methods delegate to a memoized `@@instance`; `@@instance` is reset
  #   to nil via `reset!` (test hook, replaces ruby_llm's
  #   `instance_variable_set(:@instance, nil)`).
  # - `by_provider`/`by_family` accept `String` (symbols-as-runtime-data → String,
  #   design §11). A `Symbol` overload is NOT provided (symbols are compile-time
  #   constants in Crystal; runtime "openai".to_sym doesn't exist).
  # - Bedrock region-prefix resolution (`resolve_bedrock_region_id`) is deferred
  #   (depends on `Providers::Bedrock` and a live Configuration).
  # - PROVIDER_PREFERENCE ordering is preserved for `find`'s preferred_match.
  class Models
    include Enumerable(Model::Info)

    MODELS_JSON = {{ read_file("#{__DIR__}/models.json") }}

    PROVIDER_PREFERENCE = %w[
      openai
      anthropic
      gemini
      vertexai
      bedrock
      openrouter
      deepseek
      mistral
      perplexity
      xai
      azure
      ollama
      gpustack
    ]

    # ---- Singleton instance ----

    @@instance : Models? = nil

    # Returns the shared singleton, creating it on first call.
    def self.instance : Models
      @@instance ||= new
    end

    # Resets the singleton (test hook — mirrors ruby_llm's
    # `instance_variable_set(:@instance, nil)`).
    def self.reset! : Nil
      @@instance = nil
    end

    # ---- Class-level delegates ----

    def self.all : Array(Model::Info)
      instance.all
    end

    def self.each(&)
      instance.each { |info| yield info }
    end

    def self.find(model_id : String, provider : String? = nil) : Model::Info
      instance.find(model_id, provider)
    end

    # Returns just the Model::Info half of ruby_llm's `[model, provider_instance]`
    # tuple. The provider-instance half is DEFERRED (see class-level comment).
    def self.resolve(model_id : String, provider : String? = nil, assume_exists : Bool = false) : Model::Info
      instance.resolve(model_id, provider: provider, assume_exists: assume_exists)
    end

    def self.by_provider(slug : String) : Models
      instance.by_provider(slug)
    end

    def self.by_family(family : String) : Models
      instance.by_family(family)
    end

    def self.chat_models : Models
      instance.chat_models
    end

    def self.embedding_models : Models
      instance.embedding_models
    end

    def self.audio_models : Models
      instance.audio_models
    end

    def self.image_models : Models
      instance.image_models
    end

    # DEFERRED: hits models.dev; requires Connection / HTTP layer.
    def self.refresh! : NoReturn
      raise NotImplementedError.new(
        "Models.refresh! is deferred. It hits models.dev over the network and " \
        "depends on the Connection layer (not yet ported). Track in PORTING.md."
      )
    end

    # DEFERRED: writes registry back to disk; meaningful only post-refresh!.
    def self.save_to_json(_file : String? = nil) : NoReturn
      raise NotImplementedError.new(
        "Models.save_to_json is deferred (depends on refresh! / runtime mutation)."
      )
    end

    # ---- Constructor ----

    @models : Array(Model::Info)

    # Pass a pre-built array to skip loading (useful in tests and for filtered
    # sub-registries). nil → load from embedded JSON.
    def initialize(models : Array(Model::Info)? = nil)
      @models = self.class.filter_models(models || self.class.load_models)
    end

    # ---- Core API ----

    def all : Array(Model::Info)
      @models
    end

    def each(&)
      @models.each { |info| yield info }
    end

    def empty? : Bool
      @models.empty?
    end

    def size : Int32
      @models.size
    end

    # Finds a model by id (and optionally provider).
    # Raises ModelNotFoundError when no match is found.
    # Alias resolution is applied: exact id first, then alias.
    def find(model_id : String, provider : String? = nil) : Model::Info
      if prov = provider
        find_with_provider(model_id, prov)
      else
        find_without_provider(model_id)
      end
    end

    # Returns the Model::Info for *model_id*.
    # DEFERRED: ruby_llm returns `[Model::Info, ProviderInstance]`.
    # This port returns only the Model::Info until Provider instantiation is
    # available. See class-level DEFERRED comment.
    def resolve(model_id : String, provider : String? = nil, assume_exists : Bool = false) : Model::Info
      if assume_exists
        raise ArgumentError.new("Provider must be specified if assume_exists is true") unless provider
        prov = provider # narrowed to String
        begin
          find(model_id, prov)
        rescue ModelNotFoundError
          Model::Info.default(model_id, prov)
        end
      else
        find(model_id, provider)
      end
    end

    def chat_models : Models
      Models.new(@models.select { |info| info.type == "chat" })
    end

    def embedding_models : Models
      Models.new(@models.select { |info| info.type == "embedding" || info.modalities.output.includes?("embeddings") })
    end

    def audio_models : Models
      Models.new(@models.select { |info| info.type == "audio" || info.modalities.output.includes?("audio") })
    end

    def image_models : Models
      Models.new(@models.select { |info| info.type == "image" || info.modalities.output.includes?("image") })
    end

    def by_provider(slug : String) : Models
      Models.new(@models.select { |info| info.provider == slug })
    end

    def by_family(family : String) : Models
      Models.new(@models.select { |info| info.family == family })
    end

    # DEFERRED: depends on Connection layer.
    def refresh! : NoReturn
      self.class.refresh!
    end

    # DEFERRED: depends on refresh!.
    def save_to_json(_file : String? = nil) : NoReturn
      self.class.save_to_json
    end

    # DEFERRED: belongs in crystal-llm-marten (ActiveRecord).
    def load_from_database! : NoReturn
      raise NotImplementedError.new(
        "load_from_database! is deferred to crystal-llm-marten (ActiveRecord)."
      )
    end

    # ---- Class helpers ----

    # Parses the compile-time-embedded models.json and returns a filtered array.
    def self.load_models : Array(Model::Info)
      parsed = JSON.parse(MODELS_JSON)
      models = parsed.as_a.map do |entry|
        Model::Info.new(entry.as_h)
      end
      filter_models(models)
    rescue JSON::ParseException
      [] of Model::Info
    end

    # Removes vertexai models with slash-delimited IDs (ruby_llm parity).
    def self.filter_models(models : Array(Model::Info)) : Array(Model::Info)
      models.reject do |info|
        info.provider.to_s == "vertexai" && info.id.to_s.includes?("/")
      end
    end

    # ---- Private helpers ----

    private def find_with_provider(model_id : String, provider : String) : Model::Info
      resolved_id = Aliases.resolve(model_id, provider)
      # Exact id match (post-alias-resolve) takes precedence
      match = @models.find { |info| info.id == resolved_id && info.provider == provider }
      return match if match

      # Fall back to the raw requested id (alias may not have resolved)
      match = @models.find { |info| info.id == model_id && info.provider == provider }
      return match if match

      raise_model_not_found(model_id, provider: provider)
    end

    private def find_without_provider(model_id : String) : Model::Info
      exact = @models.select { |info| info.id == model_id }
      return preferred_match(exact) unless exact.empty?

      resolved_id = Aliases.resolve(model_id)
      alias_matches = @models.select { |info| info.id == resolved_id }
      return preferred_match(alias_matches) unless alias_matches.empty?

      raise_model_not_found(model_id)
    end

    private def preferred_match(candidates : Array(Model::Info)) : Model::Info
      return candidates.first if candidates.size == 1

      candidates.min_by do |info|
        idx = PROVIDER_PREFERENCE.index(info.provider.to_s)
        idx || PROVIDER_PREFERENCE.size
      end
    end

    private def raise_model_not_found(model_id : String, provider : String? = nil) : NoReturn
      msg = "Unknown model: #{model_id.inspect}"
      msg = "#{msg} for provider: #{provider.inspect}" if provider
      raise ModelNotFoundError.new(
        "#{msg}. If the model exists at the provider, refresh the registry with " \
        "`CrystalLLM::Models.refresh!` and persist it with " \
        "`CrystalLLM::Models.save_to_json`."
      )
    end
  end
end
