# ported from lib/ruby_llm/image.rb @ ruby_llm 1.15.0
require "base64"
require "./tokens"
require "./connection"

module CrystalLLM
  # Represents a generated image from an AI model.
  #
  # An image is either remote (a `url` you fetch) or inline base64 (`data` plus a
  # `mime_type`). `base64?` distinguishes the two; `to_blob`/`save` materialize the
  # bytes.
  #
  # == Divergences from ruby_llm (documented, idiomatic Crystal) ==
  #
  # * `usage` is `Hash(String, JSON::Any)` (the port's JSONData wire shape) rather
  #   than a symbol-or-string-keyed Ruby hash. ruby_llm's `usage_value(key)` reads
  #   `usage[key] || usage[key.to_sym]`; here keys are always strings, so
  #   `usage_value` reads the string key only.
  # * `Image.paint` (the class method that resolves a model and calls a provider)
  #   is DEFERRED: it needs the `Models` registry and a `Provider` instance, neither
  #   of which is ported yet. See `deferrals`.
  # * `#cost` / `#model_info` are DEFERRED: they need the `Cost` value object and
  #   the `Models` registry. `#tokens` (which only needs `Tokens`) is ported.
  class Image
    getter url : String?
    getter data : String?
    getter mime_type : String?
    getter revised_prompt : String?
    getter model_id : String?
    getter usage : Hash(String, JSON::Any)

    def initialize(@url : String? = nil, @data : String? = nil, @mime_type : String? = nil,
                   @revised_prompt : String? = nil, @model_id : String? = nil,
                   usage : Hash(String, JSON::Any)? = nil)
      @usage = usage || {} of String => JSON::Any
    end

    # True for an inline base64 image (i.e. `data` is present), false for a
    # url-backed image.
    def base64? : Bool
      !@data.nil?
    end

    # Returns the raw image bytes. For a base64 image this decodes `data`; for a
    # url-backed image it fetches the bytes via `Connection.basic_get` (ruby_llm's
    # `Connection.basic.get(url).body`).
    def to_blob : Bytes
      if encoded = @data
        Base64.decode(encoded)
      elsif fetch_url = @url
        Connection.basic_get(fetch_url).body.to_slice
      else
        raise ArgumentError.new("Image has neither data nor url to materialize")
      end
    end

    # Writes the image bytes to `path` (expanded) and returns `path`.
    def save(path : String) : String
      File.write(File.expand_path(path), to_blob)
      path
    end

    # Token usage for the paint request, or nil if usage is empty. Mirrors
    # ruby_llm's memoized `#tokens`.
    def tokens : Tokens?
      @tokens ||= Tokens.build(
        input: usage_value("input_tokens"),
        output: usage_value("output_tokens"),
      )
    end

    # NOTE: `#cost` and `#model_info` are deferred (need Cost + Models registry).
    # NOTE: `Image.paint` is deferred (needs Models registry + Provider instance).

    @tokens : Tokens?

    private def usage_value(key : String) : Int32?
      value = @usage[key]?
      return nil unless value

      value.as_i?
    end
  end
end
