# ported from lib/ruby_llm/image.rb @ ruby_llm 1.15.0
require "base64"
require "./tokens"
require "./connection"
require "./cost"
require "./models"
require "./model/info"
require "./error"

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
  # * `#cost` / `#model_info` are ported. `#model_info` resolves the model via
  #   `Models.find(model_id)` (ruby_llm's `RubyLLM.models.find`), swallowing
  #   `ModelNotFoundError` to nil. `#cost` builds a `Cost` in the `:images`
  #   category, passing `input_tokens_details` (text/image token split) through.
  #   ruby_llm reads `usage_value('input_tokens_details')` as a string/symbol-keyed
  #   hash; here `usage["input_tokens_details"]` is a `JSON::Any` object, coerced
  #   to the `Hash(String, Int32?)` that `Cost` expects (only the
  #   "text_tokens"/"image_tokens" keys are consumed downstream).
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

    # Cost of the paint request, in the `:images` pricing category. Mirrors
    # ruby_llm's `Cost.new(tokens:, model: model_info, category: :images,
    # input_details: input_tokens_details)`.
    def cost : Cost
      Cost.new(
        tokens: tokens,
        model: model_info,
        category: Cost::Category::Images,
        input_details: input_tokens_details,
      )
    end

    # The registry `Model::Info` for this image's `model_id`, or nil when there
    # is no model id or the id isn't in the registry. Mirrors ruby_llm's
    # `RubyLLM.models.find(model_id)` rescuing `ModelNotFoundError`.
    def model_info : Model::Info?
      id = @model_id
      return nil unless id

      @model_info ||= begin
        Models.find(id)
      rescue ModelNotFoundError
        nil
      end
    end

    # NOTE: `Image.paint` is deferred (needs Models registry + Provider instance).

    @tokens : Tokens?
    @model_info : Model::Info?

    # ruby_llm's private `input_tokens_details` — the per-modality input token
    # split (text vs image) used by `Cost` when category is `:images`. Returns
    # nil when usage carries no such detail. The wire value is a JSON object;
    # coerce its numeric entries into the `Hash(String, Int32?)` `Cost` expects.
    private def input_tokens_details : Hash(String, Int32?)?
      value = @usage["input_tokens_details"]?
      return nil unless value

      obj = value.as_h?
      return nil unless obj

      details = {} of String => Int32?
      obj.each do |key, inner|
        details[key] = case raw = inner.raw
                       when Int64   then raw.to_i32
                       when Int32   then raw
                       when Float64 then raw.to_i32
                       else              nil
                       end
      end
      details
    end

    private def usage_value(key : String) : Int32?
      value = @usage[key]?
      return nil unless value

      value.as_i?
    end
  end
end
