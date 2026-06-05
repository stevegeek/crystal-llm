# ported from lib/ruby_llm/models.rb @ ruby_llm 1.15.0
require "json"
require "crest"
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
  # IMPLEMENTED (PORTING.md #12):
  # - `refresh!`   — fetches the models.dev API (https://models.dev/api.json),
  #                  parses every provider's models into Model::Info, and replaces
  #                  the process-wide registry (`@@instance`). The network call is
  #                  routed through the OVERRIDABLE protected `fetch_models_dev_data`
  #                  hook so specs can stub it with a fixture (NO live call in specs).
  # - `save_to_json` — writes the current registry to a path as a JSON array of
  #                    `Model::Info#to_h` (round-trips through `read_from_json`).
  #
  # DEFERRED (from ruby_llm):
  # - `refresh!` PROVIDER-FETCH + MERGE half — ruby_llm also calls each configured
  #   provider's `list_models` and merges that with the models.dev data
  #   (`fetch_provider_models`/`merge_with_existing`/`add_provider_metadata`). That
  #   path depends on the Provider registry being instantiable from a live
  #   Configuration (not yet ported), so this port implements ONLY the models.dev
  #   fetch + replace. The `remote_only:` keyword is therefore irrelevant and
  #   omitted. When Provider lands, layer the merge on top of `fetch_models_dev`.
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
    }

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
    # `fetch_hook` so a stubbed fetch never leaks across specs.
    def self.reset! : Nil
      @@instance = nil
      @@fetch_hook = nil
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

    # Fetches the models.dev registry and REPLACES the process-wide singleton.
    #
    # Mirrors ruby_llm's `refresh!`, scoped to the models.dev fetch (the
    # provider-fetch + merge half is DEFERRED — see class-level comment). The HTTP
    # call is routed through `fetch_models_dev_data` (overridable) so specs can
    # stub it; on any fetch/parse failure the existing registry is kept (ruby_llm
    # "Keeping existing.").
    #
    # Returns the refreshed `Models` instance.
    def self.refresh! : Models
      models = fetch_models_dev
      @@instance = new(models) unless models.empty?
      instance
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

    # Installs a stub for the models.dev fetch (test hook). Pass `nil` to clear.
    def self.fetch_hook=(hook : Proc(JSON::Any)?) : Nil
      @@fetch_hook = hook
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

      created_date = [data["release_date"]?, data["last_updated"]?]
        .compact_map { |value| json_string(value) }
        .find { |value| !value.strip.empty? }

      built = {} of String => JSON::Any
      built["id"] = JSON::Any.new(id) if id
      built["name"] = JSON::Any.new(name) if name
      built["provider"] = JSON::Any.new(provider_slug)
      if family = json_string(data["family"]?)
        built["family"] = JSON::Any.new(family)
      end
      if created_date
        built["created_at"] = JSON::Any.new("#{created_date} 00:00:00 UTC")
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

    # ruby_llm `models_dev_capabilities`.
    def self.models_dev_capabilities(data : Hash(String, JSON::Any), modalities : Hash(String, Array(String))) : Array(String)
      capabilities = [] of String
      capabilities << "function_calling" if json_truthy(data["tool_call"]?)
      capabilities << "structured_output" if json_truthy(data["structured_output"]?)
      capabilities << "reasoning" if json_truthy(data["reasoning"]?)
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
    def self.models_dev_metadata(data : Hash(String, JSON::Any), provider_key : String) : JSON::Any
      metadata = {} of String => JSON::Any
      metadata["source"] = JSON::Any.new("models.dev")
      metadata["provider_id"] = JSON::Any.new(provider_key)
      %w[open_weights attachment temperature last_updated status interleaved cost limit knowledge].each do |key|
        value = data[key]?
        metadata[key] = value if value && !value.raw.nil?
      end
      JSON::Any.new(metadata)
    end

    # ruby_llm `normalize_models_dev_modalities` — Array(...).compact for each side.
    def self.normalize_models_dev_modalities(modalities_any : JSON::Any?) : Hash(String, Array(String))
      normalized = {"input" => [] of String, "output" => [] of String}
      obj = modalities_any.try(&.as_h?)
      return normalized unless obj

      normalized["input"] = json_string_array(obj["input"]?)
      normalized["output"] = json_string_array(obj["output"]?)
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
