# ported from lib/ruby_llm/provider.rb @ ruby_llm 1.15.0
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
        array.compact_map { |part| part.as_h?.try { |part_hash| extract_hash_error(part_hash) } }.join(". ")
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

    def self.configured?(config : Configuration) : Bool
      configuration_requirements.all? { |req| config.configured?(req) }
    end

    def self.configured_providers(config : Configuration) : Array(Provider.class)
      @@providers.values.select(&.configured?(config))
    end
  end
end
