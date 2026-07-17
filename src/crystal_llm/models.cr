# ported from lib/ruby_llm/models.rb @ ruby_llm 1.16.0
require "json"
require "crest"
require "./error"
require "./model/info"
require "./utils"

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

    # models.dev API endpoint (ruby_llm hard-codes the same URL).
    MODELS_DEV_URL = "https://models.dev/api.json"

    # ruby_llm's MODELS_DEV_PROVIDER_MAP: maps a models.dev provider key to the
    # CrystalLLM provider slug. Keys absent from this map are skipped (ruby_llm
    # `next [] unless provider_slug`).
    MODELS_DEV_PROVIDER_MAP = {
      "openai"         => "openai",
      "anthropic"      => "anthropic",
      "google"         => "gemini",
      "google-vertex"  => "vertexai",
      "amazon-bedrock" => "bedrock",
      "deepseek"       => "deepseek",
      "mistral"        => "mistral",
      "openrouter"     => "openrouter",
      "perplexity"     => "perplexity",
      "xai"            => "xai",
    }

    # models.dev-allowed modality vocab (ruby_llm 3f27b864). Any value outside
    # these sets is dropped by `normalize_models_dev_modalities` — models.dev is
    # the authority on which modality tags exist.
    MODELS_DEV_INPUT_MODALITIES  = %w[text image audio pdf video file]
    MODELS_DEV_OUTPUT_MODALITIES = %w[text image audio video embeddings moderation]

    # Capabilities models.dev is the authority for (ruby_llm 3f27b864). When
    # merging provider + models.dev data in `add_provider_metadata`, a provider's
    # OWN claim to one of these is dropped unless models.dev also grants it —
    # only non-authority provider capabilities (e.g. "streaming", "batch") pass
    # through unconditionally.
    MODELS_DEV_AUTHORITY_CAPABILITIES = %w[function_calling structured_output reasoning vision]

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
    # `instance_variable_set(:@instance, nil)`). Also clears any installed
    # `fetch_hook`/`existing_models_hook`/`db_source` so stubs never leak across specs.
    def self.reset! : Nil
      @@instance = nil
      @@fetch_hook = nil
      @@existing_models_hook = nil
      @@db_source = nil
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

    # Fetches models from all configured providers AND from models.dev, merges them,
    # and REPLACES the process-wide singleton.
    #
    # Mirrors ruby_llm's `refresh!(remote_only:)` in full:
    #   load_existing_models → fetch_provider_models → fetch_models_dev_models
    #   → merge_with_existing → new(merged)
    #
    # *remote_only* — when true, skip local providers (ruby_llm parity).
    #
    # The models.dev HTTP call is routed through `fetch_models_dev_data` so specs
    # can stub it (no live network in tests). Provider `list_models` calls are made
    # directly via the provider instance; specs inject fake providers that return
    # canned data. On any provider fetch failure the existing models for that
    # provider are preserved (ruby_llm parity).
    #
    # Returns the refreshed `Models` instance.
    def self.refresh!(remote_only : Bool = false) : Models
      existing_models = load_existing_models

      provider_fetch = fetch_provider_models(remote_only: remote_only)
      models_dev_fetch = fetch_models_dev_models(existing_models)

      merged = merge_with_existing(existing_models, provider_fetch, models_dev_fetch)
      @@instance = new(merged)
      instance
    end

    # ProviderFetchResult holds the result of `fetch_provider_models`.
    # Mirrors ruby_llm's Hash result shape: models, fetched_providers, failed.
    # Using a struct for type safety (avoids generic Hash(String, T) juggling).
    struct ProviderFetchResult
      getter models : Array(Model::Info)
      getter fetched_providers : Array(String)
      getter failed : Array(NamedTuple(slug: String, error: Exception))

      def initialize(
        @models : Array(Model::Info),
        @fetched_providers : Array(String),
        @failed : Array(NamedTuple(slug: String, error: Exception)),
      )
      end
    end

    # ModelDevFetchResult holds the result of `fetch_models_dev_models`.
    # Mirrors ruby_llm's `{ models:, fetched: }` shape.
    struct ModelsDevFetchResult
      getter models : Array(Model::Info)
      getter? fetched : Bool

      def initialize(@models : Array(Model::Info), @fetched : Bool)
      end
    end

    # ruby_llm `fetch_provider_models` — iterates configured providers, calls
    # `list_models`, and collects results. Provider failures are caught: the
    # provider's slug is added to `failed` but not to `fetched_providers`, so
    # `merge_with_existing` will preserve the old models for that provider.
    def self.fetch_provider_models(remote_only : Bool = true) : ProviderFetchResult
      config = CrystalLLM.config
      provider_classes = remote_only ? Provider.remote_providers : Provider.providers.values

      models = [] of Model::Info
      fetched_providers = [] of String
      failed = [] of NamedTuple(slug: String, error: Exception)

      provider_classes.each do |provider_class|
        next if remote_only && provider_class.local?
        next unless provider_class.configured?(config)

        begin
          provider_instance = provider_class.new(config)
          models.concat(provider_instance.list_models)
          fetched_providers << provider_class.slug unless fetched_providers.includes?(provider_class.slug)
        rescue ex : Exception
          failed << {slug: provider_class.slug, error: ex}
        end
      end

      ProviderFetchResult.new(
        models: models,
        fetched_providers: fetched_providers,
        failed: failed
      )
    end

    # Backwards-compatible wrapper (ruby_llm spec-only method).
    # Returns just the models array from `fetch_provider_models`.
    def self.fetch_from_providers(remote_only : Bool = true) : Array(Model::Info)
      fetch_provider_models(remote_only: remote_only).models
    end

    # ruby_llm `fetch_models_dev_models(existing_models)` — fetches models.dev and
    # parses them; on failure falls back to the subset of existing_models that came
    # from models.dev (preserving cached data, ruby_llm parity).
    def self.fetch_models_dev_models(existing_models : Array(Model::Info)) : ModelsDevFetchResult
      data = fetch_models_dev_data
      models_raw = parse_models_dev(data)
      # Only keep models whose id and provider are present (ruby_llm: `.reject { nil? }`)
      fetched = models_raw.reject { |info| info.id.nil? || info.provider.nil? }
      ModelsDevFetchResult.new(models: fetched, fetched: true)
    rescue ex : Crest::RequestFailed | IO::Error | JSON::ParseException
      # On failure keep the previously-fetched models.dev subset (ruby_llm parity).
      cached = existing_models.select do |info|
        meta = info.metadata
        src = meta["source"]?
        src && src.as_s? == "models.dev"
      end
      ModelsDevFetchResult.new(models: cached, fetched: false)
    end

    # ruby_llm `load_existing_models` — returns the current singleton's models if
    # loaded, else falls back to the compile-time-embedded JSON.
    # When `@@existing_models_hook` is set (test seam), returns its result instead.
    def self.load_existing_models : Array(Model::Info)
      if hook = @@existing_models_hook
        return hook.call
      end

      existing = @@instance.try(&.all)
      return existing if existing && !existing.empty?

      load_models
    end

    # ruby_llm `merge_with_existing` — three-way merge of existing models,
    # fresh provider-fetch results, and models.dev data.
    #
    # Providers that were successfully fetched have their old models replaced
    # entirely; providers that failed to fetch keep their old models. The merged
    # provider list is then merged with models.dev via `merge_models`.
    def self.merge_with_existing(
      existing_models : Array(Model::Info),
      provider_fetch : ProviderFetchResult,
      models_dev_fetch : ModelsDevFetchResult,
    ) : Array(Model::Info)
      # Group existing by provider; drop providers we just fetched fresh data for.
      existing_by_provider = existing_models.group_by(&.provider.to_s)
      preserved_models = existing_by_provider
        .reject { |slug, _| provider_fetch.fetched_providers.includes?(slug) }
        .values
        .flatten

      provider_models = provider_fetch.models + preserved_models

      models_dev_models = if models_dev_fetch.fetched?
                            models_dev_fetch.models
                          else
                            existing_models.select do |info|
                              info.metadata["source"]?.try(&.as_s?) == "models.dev"
                            end
                          end

      merge_models(provider_models, models_dev_models)
    end

    # ruby_llm `merge_models` — key-based outer join of provider models and
    # models.dev models. For each key:
    # - Both present → `add_provider_metadata` (models.dev wins; provider fills blanks)
    # - models.dev only → use as-is
    # - provider only → use as-is
    # The result is `filter_models`-ed and sorted by [provider, id] (ruby_llm parity).
    def self.merge_models(
      provider_models : Array(Model::Info),
      models_dev_models : Array(Model::Info),
    ) : Array(Model::Info)
      models_dev_by_key = index_by_key(models_dev_models)
      provider_by_key = index_by_key(provider_models)

      all_keys = (models_dev_by_key.keys + provider_by_key.keys).uniq!

      merged = all_keys.compact_map do |key|
        md_model = find_models_dev_model(key, models_dev_by_key)
        prov_model = provider_by_key[key]?

        if md_model && prov_model
          add_provider_metadata(md_model, prov_model)
        elsif md_model
          md_model
        else
          # prov_model is guaranteed non-nil: the key came from provider_by_key.keys.
          # compact_map drops nil (which can't happen here, but the union type requires it).
          prov_model
        end
      end

      filter_models(merged).sort_by { |info| {info.provider.to_s, info.id.to_s} }
    end

    # ruby_llm `find_models_dev_model` — looks up *key* ("provider:id") in the
    # models.dev index with two special-cases:
    # 1. Bedrock: strip leading region prefix (e.g. "us.") and strip ":Nk" context
    #    override suffix, then look up; if found, return a copy with the original id
    #    (and the overridden context_window if present).
    # 2. VertexAI: look up the same model id under "gemini" and return a copy with
    #    provider set to "vertexai".
    def self.find_models_dev_model(key : String, models_dev_by_key : Hash(String, Model::Info)) : Model::Info?
      return models_dev_by_key[key] if models_dev_by_key.has_key?(key)

      colon_idx = key.index(':')
      return nil unless colon_idx

      provider = key[0...colon_idx]
      model_id = key[(colon_idx + 1)..]

      if provider == "bedrock"
        # Strip two-letter region prefix (e.g. "us.", "eu.")
        normalized_id = model_id.sub(/^[a-z]{2}\./, "")
        context_override = nil

        # Strip ":Nk" context override suffix (e.g. ":200k" → context_override=200000)
        normalized_id = normalized_id.gsub(/:(\d+)k\b/) do |_match|
          ctx_str = $~[1]
          context_override = ctx_str.to_i * 1000
          ""
        end

        bedrock_model = models_dev_by_key["bedrock:#{normalized_id}"]?
        if bedrock_model
          # Return copy with original model_id (and context override if present)
          data = info_to_string_hash(bedrock_model)
          data["id"] = JSON::Any.new(model_id)
          data["context_window"] = JSON::Any.new(context_override.to_i64) if context_override
          return Model::Info.new(data)
        end
      end

      return nil unless provider == "vertexai"

      gemini_model = models_dev_by_key["gemini:#{model_id}"]?
      return nil unless gemini_model

      # Return Gemini's models.dev data but with vertexai as provider.
      data = info_to_string_hash(gemini_model)
      data["provider"] = JSON::Any.new("vertexai")
      Model::Info.new(data)
    end

    # ruby_llm `index_by_key` — builds a "provider:id" → Model::Info lookup Hash.
    def self.index_by_key(models : Array(Model::Info)) : Hash(String, Model::Info)
      result = {} of String => Model::Info
      models.each do |info|
        key = "#{info.provider}:#{info.id}"
        result[key] = info
      end
      result
    end

    # ruby_llm `add_provider_metadata` — returns a new Model::Info starting from
    # the models.dev model, filling blank fields from the provider model, merging
    # metadata (provider metadata as base, models.dev metadata overwrites), and
    # unioning capabilities.
    def self.add_provider_metadata(models_dev_model : Model::Info, provider_model : Model::Info) : Model::Info
      data = info_to_string_hash(models_dev_model)

      fill_blank_scalar_fields(data, provider_model)
      fill_blank_modalities(data, provider_model)
      fill_blank_pricing(data, provider_model)

      # Metadata: provider metadata as base, then models.dev metadata overwrites.
      merged_meta = {} of String => JSON::Any
      provider_model.metadata.each { |key, val| merged_meta[key] = val }
      models_dev_model.metadata.each { |key, val| merged_meta[key] = val }
      data["metadata"] = JSON::Any.new(merged_meta)

      # Capabilities: union (models.dev + provider), but a provider's OWN claim
      # to an "authority" capability (function_calling/structured_output/
      # reasoning/vision) is dropped unless models.dev also grants it — models.dev
      # is the source of truth for those; only non-authority provider
      # capabilities (streaming, batch, citations, ...) pass through unconditionally.
      provider_capabilities = provider_model.capabilities - MODELS_DEV_AUTHORITY_CAPABILITIES
      combined_caps = (models_dev_model.capabilities + provider_capabilities).uniq
      data["capabilities"] = JSON::Any.new(combined_caps.map { |cap| JSON::Any.new(cap) })

      # Re-normalize embedding modalities.
      normalize_embedding_modalities(data, data["id"]?.try(&.as_s?))

      Model::Info.new(data)
    end

    # Fills blank string/int scalar fields in *data* from the provider model.
    private def self.fill_blank_scalar_fields(
      data : Hash(String, JSON::Any),
      provider_model : Model::Info,
    ) : Nil
      data["name"] = JSON::Any.new(provider_model.name.to_s) if blank_value?(data["name"]?)
      data["family"] = JSON::Any.new(provider_model.family.to_s) if blank_value?(data["family"]?)
      if blank_value?(data["created_at"]?)
        if created = provider_model.created_at
          data["created_at"] = JSON::Any.new(created.to_s)
        end
      end
      if blank_value?(data["context_window"]?)
        if cw = provider_model.context_window
          data["context_window"] = JSON::Any.new(cw.to_i64)
        end
      end
      if blank_value?(data["max_output_tokens"]?)
        if mo = provider_model.max_output_tokens
          data["max_output_tokens"] = JSON::Any.new(mo.to_i64)
        end
      end
    end

    # Fills blank modalities in *data* from the provider model.
    private def self.fill_blank_modalities(
      data : Hash(String, JSON::Any),
      provider_model : Model::Info,
    ) : Nil
      return unless blank_value?(data["modalities"]?)

      prov_mods = provider_model.modalities
      data["modalities"] = JSON::Any.new({
        "input"  => JSON::Any.new(prov_mods.input.map { |mod_str| JSON::Any.new(mod_str) }),
        "output" => JSON::Any.new(prov_mods.output.map { |mod_str| JSON::Any.new(mod_str) }),
      })
    end

    # Fills blank pricing in *data* from the provider model.
    private def self.fill_blank_pricing(
      data : Hash(String, JSON::Any),
      provider_model : Model::Info,
    ) : Nil
      data["pricing"] = pricing_to_any(provider_model.pricing) if blank_value?(data["pricing"]?)
    end

    # ruby_llm `blank_value?` — a JSON::Any value is blank when it is nil, an empty
    # string, an empty array, or a hash whose every nested value is blank.
    def self.blank_value?(value : JSON::Any?) : Bool
      return true if value.nil?

      raw = value.raw
      case raw
      when Nil
        true
      when String
        raw.empty?
      when Array
        raw.empty?
      when Hash
        return true if raw.empty?
        # A hash is blank only if ALL nested values are blank.
        raw.all? { |_key, nested| blank_value?(nested.as(JSON::Any)) }
      else
        false
      end
    end

    # Fetches + parses the models.dev API into an array of Model::Info.
    # On failure logs nothing (no logger ported) and returns an empty array so
    # `refresh!` keeps the existing registry (ruby_llm parity).
    def self.fetch_models_dev : Array(Model::Info)
      data = fetch_models_dev_data
      parse_models_dev(data)
    rescue ex : Crest::RequestFailed | IO::Error | JSON::ParseException
      # Network/parse failure: ruby_llm warns and keeps the existing registry.
      # (Socket::Error < IO::Error, so connection failures are covered.)
      [] of Model::Info
    end

    # OVERRIDABLE network hook (a class-level Proc). When set, `fetch_models_dev_data`
    # invokes it instead of hitting the network — this is how specs stub the fetch
    # so NO live network call happens in the test suite. Set via `fetch_hook=` and
    # clear with `reset!`/`clear_fetch_hook`.
    @@fetch_hook : Proc(JSON::Any)? = nil

    # OVERRIDABLE existing-models hook (test hook). When set, `load_existing_models`
    # returns the hook's result instead of reading `@@instance` / embedded JSON.
    # Lets specs start `refresh!` from a clean slate without touching the embedded
    # registry. Cleared by `reset!`.
    @@existing_models_hook : Proc(Array(Model::Info))? = nil

    # Installs a stub for the models.dev fetch (test hook). Pass `nil` to clear.
    def self.fetch_hook=(hook : Proc(JSON::Any)?) : Nil
      @@fetch_hook = hook
    end

    # Installs a stub for `load_existing_models` (test hook). Pass `nil` to clear.
    def self.existing_models_hook=(hook : Proc(Array(Model::Info))?) : Nil
      @@existing_models_hook = hook
    end

    def self.clear_fetch_hook : Nil
      @@fetch_hook = nil
    end

    # Performs the models.dev GET and returns the parsed top-level JSON object
    # (provider_key -> provider_data). Routes through `@@fetch_hook` when one is
    # installed (specs), otherwise makes the real Crest request.
    def self.fetch_models_dev_data : JSON::Any
      if hook = @@fetch_hook
        return hook.call
      end

      response = Crest.get(MODELS_DEV_URL)
      JSON.parse(response.body)
    end

    # Parses the models.dev top-level object into Model::Info, applying the
    # provider-key -> slug mapping and the field normalization ruby_llm performs in
    # `models_dev_model_to_info`. Skips providers absent from MODELS_DEV_PROVIDER_MAP
    # and any model missing an id.
    def self.parse_models_dev(data : JSON::Any) : Array(Model::Info)
      providers = data.as_h?
      return [] of Model::Info unless providers

      models = [] of Model::Info
      providers.each do |provider_key, provider_data|
        provider_slug = MODELS_DEV_PROVIDER_MAP[provider_key]?
        next unless provider_slug

        provider_obj = provider_data.as_h?
        next unless provider_obj

        model_map = provider_obj["models"]?.try(&.as_h?)
        next unless model_map

        model_map.each_value do |model_data|
          info = models_dev_model_to_info(model_data, provider_slug, provider_key)
          next if info.nil?
          next if info.id.nil? || info.provider.nil?

          models << info
        end
      end
      filter_models(models)
    end

    # Persists the current registry to *file* as a JSON array of `Model::Info#to_h`.
    # ruby_llm: `File.write(file, JSON.pretty_generate(all.map(&:to_h)))`.
    def self.save_to_json(file : String) : Nil
      instance.save_to_json(file)
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

    # Delegates to `Models.refresh!` (replaces the process-wide registry).
    def refresh! : Models
      self.class.refresh!
    end

    # Persists THIS registry instance to *file* as a JSON array of
    # `Model::Info#to_h` (ruby_llm: `File.write(file, JSON.pretty_generate(...))`).
    def save_to_json(file : String) : Nil
      payload = @models.map { |info| stringify_keys(info.to_h) }
      File.write(file, payload.to_pretty_json)
    end

    # Registerable database source hook (Task 3b).
    # Set to a `Proc` that returns an `Array(Model::Info)` to swap the registry
    # from a database (e.g. crystal-llm-marten's `LlmModel`). Cleared by `reset!`.
    @@db_source : Proc(Array(Model::Info))? = nil

    # Installs (or clears) the database source used by `load_from_database!`.
    def self.db_source=(hook : Proc(Array(Model::Info))?) : Nil
      @@db_source = hook
    end

    # Replaces the in-memory registry with rows returned by the configured
    # `db_source` proc. Raises a clear error when no source has been registered —
    # callers must configure `Models.db_source` (e.g. via crystal-llm-marten's
    # `acts_as_model` integration) before calling this.
    def load_from_database! : Nil
      source = @@db_source
      raise NotImplementedError.new(
        "Models.db_source is not configured. Set it via Models.db_source = -> { ... } " \
        "(e.g. crystal-llm-marten's acts_as_model integration) before calling load_from_database!."
      ) unless source

      @models = self.class.filter_models(source.call)
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

    # Parses a JSON array file of `Model::Info#to_h` back into Model::Info
    # (ruby_llm's `read_from_json`). Returns [] on a missing file or parse error.
    # Used to round-trip `save_to_json` and to load a refreshed registry from disk.
    def self.read_from_json(file : String) : Array(Model::Info)
      return [] of Model::Info unless File.exists?(file)

      parsed = JSON.parse(File.read(file))
      arr = parsed.as_a?
      return [] of Model::Info unless arr

      models = arr.compact_map do |entry|
        obj = entry.as_h?
        obj ? Model::Info.new(obj) : nil
      end
      filter_models(models)
    rescue JSON::ParseException
      [] of Model::Info
    end

    # ---- models.dev parsing helpers (ruby_llm class << self block) ----

    # ruby_llm's `models_dev_model_to_info` — builds a Model::Info from one
    # models.dev model entry. Returns nil if the entry isn't an object.
    def self.models_dev_model_to_info(model_data : JSON::Any, provider_slug : String, provider_key : String) : Model::Info?
      data = model_data.as_h?
      return nil unless data

      id = json_string(data["id"]?)
      name = json_string(data["name"]?) || id

      limit = data["limit"]?.try(&.as_h?)
      modalities = normalize_models_dev_modalities(data["modalities"]?)
      capabilities = models_dev_capabilities(data, modalities)

      built = {} of String => JSON::Any
      built["id"] = JSON::Any.new(id) if id
      built["name"] = JSON::Any.new(name) if name
      built["provider"] = JSON::Any.new(provider_slug)
      if family = json_string(data["family"]?)
        built["family"] = JSON::Any.new(family)
      end
      if created_at = models_dev_created_at(data)
        built["created_at"] = created_at
      end
      if limit
        if ctx = json_int(limit["context"]?)
          built["context_window"] = JSON::Any.new(ctx.to_i64)
        end
        if max_out = json_int(limit["output"]?)
          built["max_output_tokens"] = JSON::Any.new(max_out.to_i64)
        end
      end
      if knowledge = normalize_models_dev_knowledge(data["knowledge"]?)
        built["knowledge_cutoff"] = JSON::Any.new(knowledge)
      end
      built["modalities"] = modalities_to_any(modalities)
      built["capabilities"] = JSON::Any.new(capabilities.map { |cap| JSON::Any.new(cap) })
      built["pricing"] = models_dev_pricing(data["cost"]?)
      built["metadata"] = models_dev_metadata(data, provider_key)

      normalize_embedding_modalities(built, id)

      Model::Info.new(built)
    end

    # ruby_llm: `created_date = [model_data[:release_date], model_data[:last_updated]].find { |value| !value.to_s.strip.empty? }`,
    # then `created_at: Utils.iso_date_prefix_to_utc_midnight_string(created_date)`
    # (ruby_llm 48f851db). release_date wins over last_updated; models.dev dates
    # arrive as date-prefixes (YYYY-MM-DD, YYYY-MM, or YYYY), not just full dates.
    def self.models_dev_created_at(data : Hash(String, JSON::Any)) : JSON::Any?
      created_date = [data["release_date"]?, data["last_updated"]?]
        .compact_map { |value| json_string(value) }
        .find { |value| !value.strip.empty? }
      return nil unless created_date

      normalized = Utils.iso_date_prefix_to_utc_midnight_string(created_date)
      normalized ? JSON::Any.new(normalized) : nil
    end

    # ruby_llm `models_dev_capabilities`. ruby_llm 3f27b864: a model is also
    # "reasoning" when it carries `reasoning_options` even if the `reasoning`
    # flag itself is false/absent (e.g. Claude's budget_tokens-only models).
    def self.models_dev_capabilities(data : Hash(String, JSON::Any), modalities : Hash(String, Array(String))) : Array(String)
      capabilities = [] of String
      capabilities << "function_calling" if json_truthy(data["tool_call"]?)
      capabilities << "structured_output" if json_truthy(data["structured_output"]?)
      capabilities << "reasoning" if json_truthy(data["reasoning"]?) || json_truthy(data["reasoning_options"]?)
      input = modalities["input"]? || [] of String
      capabilities << "vision" if input.any? { |mod| {"image", "video", "pdf"}.includes?(mod) }
      capabilities.uniq
    end

    # ruby_llm `models_dev_pricing` — reshapes the flat `cost` object into the
    # nested text_tokens/audio_tokens standard tiers. Returns a JSON object.
    def self.models_dev_pricing(cost_any : JSON::Any?) : JSON::Any
      empty = {} of String => JSON::Any
      cost = cost_any.try(&.as_h?)
      return JSON::Any.new(empty) unless cost

      text_standard = {} of String => JSON::Any
      put_float(text_standard, "input_per_million", cost["input"]?)
      put_float(text_standard, "output_per_million", cost["output"]?)
      put_float(text_standard, "cache_read_input_per_million", cost["cache_read"]?)
      put_float(text_standard, "cache_write_input_per_million", cost["cache_write"]?)
      put_float(text_standard, "reasoning_output_per_million", cost["reasoning"]?)

      audio_standard = {} of String => JSON::Any
      put_float(audio_standard, "input_per_million", cost["input_audio"]?)
      put_float(audio_standard, "output_per_million", cost["output_audio"]?)

      pricing = {} of String => JSON::Any
      unless text_standard.empty?
        pricing["text_tokens"] = JSON::Any.new({"standard" => JSON::Any.new(text_standard)})
      end
      unless audio_standard.empty?
        pricing["audio_tokens"] = JSON::Any.new({"standard" => JSON::Any.new(audio_standard)})
      end
      JSON::Any.new(pricing)
    end

    # ruby_llm `models_dev_metadata` — the `.compact` drops nil values.
    # ruby_llm 3f27b864 adds `reasoning_options` to this passthrough list; Info's
    # `store_reasoning_options_metadata` (Task 6) is what actually normalizes it
    # once it lands in `Info#metadata`.
    def self.models_dev_metadata(data : Hash(String, JSON::Any), provider_key : String) : JSON::Any
      metadata = {} of String => JSON::Any
      metadata["source"] = JSON::Any.new("models.dev")
      metadata["provider_id"] = JSON::Any.new(provider_key)
      %w[
        open_weights attachment temperature last_updated status interleaved
        reasoning_options cost limit knowledge
      ].each do |key|
        value = data[key]?
        metadata[key] = value if value && !value.raw.nil?
      end
      JSON::Any.new(metadata)
    end

    # ruby_llm `normalize_models_dev_modalities` — Array(...).compact for each
    # side, intersected with the models.dev-allowed vocab (ruby_llm 3f27b864:
    # `& MODELS_DEV_INPUT_MODALITIES` / `& MODELS_DEV_OUTPUT_MODALITIES`). Crystal's
    # `Array#&` matches Ruby's: intersection, deduplicated, receiver's order.
    def self.normalize_models_dev_modalities(modalities_any : JSON::Any?) : Hash(String, Array(String))
      normalized = {"input" => [] of String, "output" => [] of String}
      obj = modalities_any.try(&.as_h?)
      return normalized unless obj

      normalized["input"] = json_string_array(obj["input"]?) & MODELS_DEV_INPUT_MODALITIES
      normalized["output"] = json_string_array(obj["output"]?) & MODELS_DEV_OUTPUT_MODALITIES
      normalized
    end

    # ruby_llm `normalize_models_dev_knowledge` — keep a parseable YYYY-MM-DD date
    # string; return nil if absent/unparseable.
    def self.normalize_models_dev_knowledge(value : JSON::Any?) : String?
      str = json_string(value)
      return nil if str.nil? || str.strip.empty?

      begin
        Time.parse(str, "%Y-%m-%d", Time::Location::UTC)
        str
      rescue Time::Format::Error
        nil
      end
    end

    # ruby_llm `normalize_embedding_modalities` — embedding models always output
    # ["embeddings"], and default input to ["text"] when empty.
    def self.normalize_embedding_modalities(built : Hash(String, JSON::Any), id : String?) : Nil
      return unless id && id.includes?("embedding")

      mods = built["modalities"]?.try(&.as_h?) || {} of String => JSON::Any
      input = mods["input"]?.try(&.as_a?) || [] of JSON::Any
      input = [JSON::Any.new("text")] if input.empty?
      built["modalities"] = JSON::Any.new({
        "input"  => JSON::Any.new(input),
        "output" => JSON::Any.new([JSON::Any.new("embeddings")]),
      })
    end

    # ---- small JSON coercion helpers ----

    # Converts a Model::Info into the `Hash(String, JSON::Any)` shape expected by
    # `Model::Info.new`. Bridges the symbol-keyed, nullable `to_h` return type
    # to the string-keyed, non-nullable wire constructor.
    private def self.info_to_string_hash(info : Model::Info) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      info.to_h.each do |sym_key, any_val|
        next if any_val.nil?
        result[sym_key.to_s] = any_val
      end
      result
    end

    # Converts a `Model::Pricing` to a JSON::Any suitable for the `pricing` field.
    private def self.pricing_to_any(pricing : Model::Pricing) : JSON::Any
      outer = {} of String => JSON::Any
      pricing.to_h.each do |category, tiers|
        inner = {} of String => JSON::Any
        tiers.each do |tier_name, attributes|
          attrs = {} of String => JSON::Any
          attributes.each do |attr, value|
            attrs[attr.key] = JSON::Any.new(value)
          end
          inner[tier_name] = JSON::Any.new(attrs)
        end
        outer[category] = JSON::Any.new(inner)
      end
      JSON::Any.new(outer)
    end

    private def self.modalities_to_any(modalities : Hash(String, Array(String))) : JSON::Any
      JSON::Any.new(modalities.transform_values do |arr|
        JSON::Any.new(arr.map { |item| JSON::Any.new(item) })
      end)
    end

    private def self.json_string(value : JSON::Any?) : String?
      return nil if value.nil?
      value.as_s? || (value.raw.nil? ? nil : value.raw.to_s)
    end

    private def self.json_string_array(value : JSON::Any?) : Array(String)
      arr = value.try(&.as_a?)
      return [] of String unless arr
      arr.compact_map { |element| json_string(element) }
    end

    private def self.json_int(value : JSON::Any?) : Int32?
      return nil if value.nil?
      case raw = value.raw
      when Int64   then raw.to_i32
      when Int32   then raw
      when Float64 then raw.to_i32
      else              nil
      end
    end

    private def self.json_float(value : JSON::Any?) : Float64?
      return nil if value.nil?
      case raw = value.raw
      when Float64 then raw
      when Int64   then raw.to_f
      when Int32   then raw.to_f
      else              nil
      end
    end

    private def self.put_float(target : Hash(String, JSON::Any), key : String, value : JSON::Any?) : Nil
      num = json_float(value)
      target[key] = JSON::Any.new(num) if num
    end

    private def self.json_truthy(value : JSON::Any?) : Bool
      return false if value.nil?
      raw = value.raw
      return raw if raw.is_a?(Bool)
      !raw.nil?
    end

    # ---- Private helpers ----

    # `Model::Info#to_h` is Symbol-keyed (JSON object keys must be Strings) and its
    # values are `JSON::Any?`; restringify the top-level keys so the array round-
    # trips through `read_from_json` (which reads String-keyed objects).
    private def stringify_keys(hash : Hash(Symbol, JSON::Any?)) : Hash(String, JSON::Any?)
      result = {} of String => JSON::Any?
      hash.each { |key, value| result[key.to_s] = value }
      result
    end

    private def find_with_provider(model_id : String, provider : String) : Model::Info
      resolved_id = Aliases.resolve(model_id, provider)
      # For Bedrock, attempt to resolve to a region-prefixed inference-profile id.
      resolved_id = resolve_bedrock_region_id(resolved_id) if provider == "bedrock"
      # Exact id match (post-alias-resolve) takes precedence
      match = @models.find { |info| info.id == resolved_id && info.provider == provider }
      return match if match

      # Fall back to the raw requested id (alias may not have resolved)
      match = @models.find { |info| info.id == model_id && info.provider == provider }
      return match if match

      raise_model_not_found(model_id, provider: provider)
    end

    # Mirrors ruby_llm's `resolve_bedrock_region_id`: when `bedrock_region` is
    # configured and a region-prefixed inference-profile variant of *model_id*
    # exists in the registry, prefer it. Uses the same logic as
    # `Providers::Bedrock#normalize_inference_profile_id` (inlined here because the
    # Bedrock provider helpers are private instance methods inaccessible from Models).
    #
    # Offline-safe: only registry lookups — no HTTP.
    private def resolve_bedrock_region_id(model_id : String) : String
      region = CrystalLLM.config.bedrock_region.to_s
      return model_id if region.empty?

      # Build the region-prefixed candidate id.
      prefix = region.split('-').first? || "us"
      prefix = "us" if prefix.empty?

      candidate_id =
        if bedrock_region_prefixed?(model_id)
          model_id.sub(/\A(?:global|us|eu|ap|sa|ca|me|af|il)\./, "#{prefix}.")
        else
          "#{prefix}.#{model_id}"
        end

      return model_id if candidate_id == model_id

      # Only prefer the prefixed id when a matching model exists and its
      # `inference_types` metadata indicates it is an INFERENCE_PROFILE
      # (not an ON_DEMAND model — which doesn't need a prefix).
      candidate = @models.find { |info| info.provider == "bedrock" && info.id == candidate_id }
      return model_id unless candidate

      inference_types = bedrock_inference_types(candidate)
      return model_id unless inference_types.includes?("INFERENCE_PROFILE")
      return model_id if inference_types.includes?("ON_DEMAND")

      candidate_id
    end

    # Extracts the `inference_types` array from a Bedrock model's metadata.
    private def bedrock_inference_types(info : Model::Info) : Array(String)
      raw = info.metadata["inference_types"]?
      return [] of String unless raw
      arr = raw.as_a?
      return [] of String unless arr
      arr.compact_map(&.as_s?)
    end

    # Returns true when *model_id* already carries a two-letter or named region
    # prefix (e.g. "us.", "eu.", "global.").
    private def bedrock_region_prefixed?(model_id : String) : Bool
      !!model_id.match(/\A(?:global|us|eu|ap|sa|ca|me|af|il)\./)
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
