# ported from lib/ruby_llm/provider.rb @ ruby_llm 1.16.0
#
# The base class for LLM providers: the class-level registry + per-instance config,
# connection, configuration checks, and provider-error extraction. Provider-specific
# hooks (api_base, render_payload, parse_completion_response, build_chunk, …) are
# raising stubs that each concrete provider overrides.
#
# NOTE: the request pipeline (complete/sync_response/embed/paint/moderate/transcribe)
# is fleshed out alongside `chat` + the first concrete provider (OpenAI), where the
# render_payload/parse signatures firm up. Tracked in PORTING.md.
require "json"
require "crest"
require "./error"
require "./connection"
require "./streaming"
require "./message"
require "./chunk"

module CrystalLLM
  class Provider
    include Streaming

    getter config : Configuration
    @connection : Connection? = nil

    def initialize(@config : Configuration)
      ensure_configured!
    end

    # The connection is built lazily (passing `self` into Connection.new at init
    # time trips Crystal's ivar-initialization analysis; lazy avoids it and does no
    # I/O until first use anyway).
    def connection : Connection
      @connection ||= Connection.new(self, @config)
    end

    # Test affordance (ruby_llm has no equivalent — its specs stub at the Faraday
    # adapter level). Lets a spec inject a `Connection` (e.g. a `StubConnection`
    # subclass returning canned `Crest::Response`s) so the FULL completion path
    # — render_payload -> connection.post -> parse_completion_response — can be
    # exercised offline. Production code never calls this; the lazy `connection`
    # accessor above is the only writer in normal use.
    def connection=(connection : Connection) : Connection
      @connection = connection
    end

    # ---- Provider hooks (overridden by concrete providers) ----

    def api_base : String
      raise "api_base must be implemented by #{self.class.provider_name}"
    end

    def headers : Hash(String, String)
      {} of String => String
    end

    def stream_url : String
      raise "stream_url must be implemented by #{self.class.provider_name}"
    end

    def build_chunk(data : JSON::Any) : Chunk
      raise "build_chunk must be implemented by #{self.class.provider_name}"
    end

    # Maps a streaming error event's JSON payload to {status, message}, or nil when
    # the payload is not an error this provider recognizes. Concrete providers that
    # surface streaming errors (Anthropic/OpenAI) override this; the default makes a
    # bare `error` key map to a generic 500 (so the stream loop still raises).
    def parse_streaming_error(data : String) : Tuple(Int32, String)?
      parsed = JSON.parse(data)
      error = parsed["error"]?
      return nil unless error

      message = error.as_h?.try { |hash| hash["message"]?.try(&.as_s?) } || error.as_s? || ""
      {500, message}
    rescue JSON::ParseException
      nil
    end

    # ---- Identity ----

    def slug : String
      self.class.slug
    end

    def name : String
      self.class.provider_name
    end

    def configuration_requirements : Array(String)
      self.class.configuration_requirements
    end

    # ---- Configuration ----

    def configured? : Bool
      self.class.configured?(@config)
    end

    # Instance delegators to the class-level locality flags (ruby_llm parity).
    def local? : Bool
      self.class.local?
    end

    def remote? : Bool
      self.class.remote?
    end

    def assume_models_exist? : Bool
      self.class.assume_models_exist?
    end

    private def ensure_configured! : Nil
      missing = self.class.configuration_requirements.reject { |req| @config.configured?(req) }
      return if missing.empty?

      raise ConfigurationError.new(
        "Missing configuration for #{name}: #{missing.join(", ")}. " \
        "Set these keys on CrystalLLM.config before using this provider."
      )
    end

    # ---- Error extraction (the provider half of the llm_errors middleware) ----

    # Extracts a human error message from a provider error response body.
    def parse_error(response : Crest::Response) : String?
      body = response.body
      return nil if body.empty?

      parsed = parse_json(body)
      return body if parsed.nil?

      if hash = parsed.as_h?
        extract_hash_error(hash)
      elsif array = parsed.as_a?
        # ruby_llm maps each part then `.join('. ')`. Ruby's `join` renders a nil
        # element as "" (not dropped), so a nil message becomes an empty segment —
        # use `... || ""` rather than `compact_map`, which would drop it.
        array.map { |part| part.as_h?.try { |part_hash| extract_hash_error(part_hash) } || "" }.join(". ")
      else
        parsed.as_s?
      end
    end

    private def extract_hash_error(hash : Hash(String, JSON::Any)) : String?
      error = hash["error"]?
      return nil unless error
      return error.as_s if error.as_s?

      error.as_h?.try { |error_hash| error_hash["message"]?.try(&.as_s?) }
    end

    private def parse_json(body : String) : JSON::Any?
      JSON.parse(body)
    rescue JSON::ParseException
      nil
    end

    # ---- Class-level registry ----

    @@providers = {} of String => Provider.class

    def self.register(name : String, provider_class : Provider.class) : Nil
      @@providers[name] = provider_class
    end

    def self.resolve(name : String) : Provider.class | ::Nil
      @@providers[name]?
    end

    def self.providers : Hash(String, Provider.class)
      @@providers
    end

    def self.provider_name : String
      to_s.split("::").last
    end

    def self.slug : String
      provider_name.downcase
    end

    def self.configuration_requirements : Array(String)
      [] of String
    end

    def self.configuration_options : Array(String)
      [] of String
    end

    # Locality flags (ruby_llm parity). A "local" provider runs against a
    # locally-hosted endpoint (e.g. Ollama); the default is remote. Concrete
    # providers override `local?` when appropriate.
    def self.local? : Bool
      false
    end

    def self.remote? : Bool
      !local?
    end

    # Whether the provider serves models not present in the registry (ruby_llm
    # uses this to skip model-existence validation, e.g. for local providers).
    def self.assume_models_exist? : Bool
      false
    end

    def self.configured?(config : Configuration) : Bool
      configuration_requirements.all? { |req| config.configured?(req) }
    end

    # Resolves the provider class that serves *model* via the model registry
    # (ruby_llm's `Provider.for`). Raises if the model isn't found.
    def self.for(model : String) : Provider.class | ::Nil
      model_info = Models.find(model)
      provider = model_info.provider
      provider.nil? ? nil : resolve(provider)
    end

    def self.local_providers : Array(Provider.class)
      @@providers.values.select(&.local?)
    end

    def self.remote_providers : Array(Provider.class)
      @@providers.values.select(&.remote?)
    end

    def self.configured_providers(config : Configuration) : Array(Provider.class)
      @@providers.values.select(&.configured?(config))
    end

    def self.configured_remote_providers(config : Configuration) : Array(Provider.class)
      @@providers.values.select { |provider_class| provider_class.remote? && provider_class.configured?(config) }
    end
  end
end
