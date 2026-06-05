# ported from lib/ruby_llm/provider.rb @ ruby_llm 1.15.0 (the media-pipeline half)
#
# Reopens CrystalLLM::Provider to add the MEDIA request pipeline (embed / paint /
# moderate / transcribe) and the provider hooks each dispatches to (raising stubs
# overridden by concrete providers). It lives in its own file (rather than
# provider.cr / provider_completion.cr) so the media surface can be ported and
# specced in isolation — mirroring how the chat-completion half lives in
# provider_completion.cr. See provider.cr's header note + PORTING.md.
#
# It ALSO carries the class-method entry points (Embedding.embed / Image.paint /
# Moderation.moderate / Transcription.transcribe) and the top-level facade shims
# (CrystalLLM.embed/paint/moderate/transcribe), reopening those classes + the
# module here rather than in their data files (which were ported pre-Provider and
# explicitly deferred these methods — see e.g. embedding.cr's DEFERRED note).
#
# == Divergences from ruby_llm's provider.rb (documented + returned) ==
#
# * Each pipeline method mirrors `Provider#embed/moderate/paint/transcribe`:
#   render a payload via a hook, POST it via `connection`, parse via a hook. Ruby
#   passes the rendered Hash to Faraday (which JSON-encodes); the port's
#   `Connection#post` takes a JSON *String*, so the pipeline calls `.to_json` on
#   the rendered `Hash(String, JSON::Any)` before posting. The parse hooks take
#   the raw `Crest::Response` (Crest does not pre-parse) and `JSON.parse` the body
#   themselves — matching how parse_completion_response works in chat.cr.
#
# * Symbols-as-runtime-data → String/enum (design §11): `text`/`input` are
#   `String | Array(String)` (ruby_llm accepts a string or array); `model` is a
#   resolved `String` id (the model's concrete id), not a Symbol.
#
# * `transcribe`'s `**options` (Ruby keyword splat) becomes an explicit
#   `opts : Hash(String, JSON::Any)` bag plus the two first-class keywords
#   `model:`/`language:` (Crystal has no `**opts` that survives to a hook with
#   arbitrary keys typed). `build_audio_file_part` returns a provider-neutral
#   `AudioFilePart` value (path + mime + filename) rather than a
#   `Faraday::Multipart::FilePart`.
#
# == MULTIPART (now ported) ==
#
# * `transcribe` and image *editing* (`with:`/`mask:` → `images/edits`) upload a
#   `multipart/form-data` body via `Connection#post_multipart` (crest emits any IO
#   form value as a file part). `build_upload_part` materializes a source into a
#   `File` part; `multipart_form` flattens the rendered non-file fields into the
#   crest form. The JSON `#post` path stays for non-file requests (embed/moderate/
#   generation). Previously DEFERRED on `Connection#post` (JSON-String body only).
#
# == DEFERRED (returned) ==
#
# * `transcribe`'s `speaker_references` encoding still depends on the not-yet-ported
#   `Attachment#for_llm` data-URL surface and raises a clear "deferred" error.
# * `instrument(...)` wrapping in the paint/moderate/transcribe class methods is
#   DEFERRED (no Ruby parity event for those). `embed` DOES emit an
#   `embedding.crystal_llm` event (a deferred-divergence IMPL added for parity with
#   `chat.crystal_llm` — ruby_llm itself has no embed instrumentation; see the
#   `#embed` pipeline below).
require "json"
require "crest"
require "./provider"
require "./provider_completion"
require "./connection"
require "./embedding"
require "./image"
require "./moderation"
require "./transcription"
require "./content"
require "./attachment"
require "./models"
require "./model/info"
require "./configuration"
require "./context"
require "./error"
require "./instrumentation"

module CrystalLLM
  class Provider
    # Accepted shapes for embed/moderate text input: a single string or a batch.
    # (ruby_llm accepts `text`/`input` as a String or an Array of Strings.)
    alias TextInput = String | Array(String)

    # A provider-neutral audio file part for transcription multipart uploads.
    # ruby_llm uses `Faraday::Multipart::FilePart`; the port carries the same three
    # fields (expanded path, mime type, basename) without the Faraday dependency.
    record AudioFilePart, path : String, mime_type : String, filename : String

    # ---- Media request pipeline (mirrors provider.rb) ----

    # Generates embedding vectors for *text* (a string or a batch). Mirrors
    # ruby_llm's `Provider#embed`, plus an `embedding.crystal_llm` instrumentation
    # event (a deferred-divergence IMPL for parity with `chat.crystal_llm` —
    # ruby_llm has no embed instrumentation). The request-side payload carries
    # provider/model/input; the response-side keys (embedding_dimensions /
    # embedding_count) are attached after the work runs. A no-op when no
    # instrumenter is configured.
    def embed(text : TextInput, model : String, dimensions : Int32? = nil) : Embedding
      event_payload = build_embedding_payload(text, model)
      CrystalLLM.instrument("embedding.crystal_llm", event_payload, config: config) do |event|
        payload = render_embedding_payload(text, model: model, dimensions: dimensions)
        response = connection.post(embedding_url(model: model), payload.to_json)
        embedding = parse_embedding_response(response, model: model, text: text)
        event["embedding_dimensions"] = Embedding.vector_dimensions(embedding.vectors)
        event["embedding_count"] = Embedding.embedding_count(embedding.vectors)
        embedding
      end
    end

    # The request-side `embedding.crystal_llm` payload (provider / model / input).
    # Mirrors `build_chat_payload`'s shape for the embed pipeline.
    private def build_embedding_payload(text : TextInput, model : String) : Instrumentation::Payload
      payload = Instrumentation::Payload.new
      payload["provider"] = slug
      payload["provider_class"] = self.class
      payload["model"] = model
      payload["input"] = text
      payload
    end

    # Runs a moderation request over *input*. Mirrors ruby_llm's `Provider#moderate`.
    def moderate(input : TextInput, model : String) : Moderation
      payload = render_moderation_payload(input, model: model)
      response = connection.post(moderation_url, payload.to_json)
      parse_moderation_response(response, model: model)
    end

    # Generates (or edits) an image. Mirrors ruby_llm's `Provider#paint`. The edit
    # path (with:/mask:) uploads the reference image(s) + optional mask as a
    # `multipart/form-data` body; the generation path posts JSON.
    def paint(prompt : String, model : String, size : String,
              with attachments : Attachable? = nil, mask : Source? = nil,
              params : Hash(String, JSON::Any) = {} of String => JSON::Any) : Image
      validate_paint_inputs!(with: attachments, mask: mask)
      url = images_url(with: attachments, mask: mask)

      response =
        if editing_image?(with: attachments, mask: mask)
          form = render_image_edit_form(prompt, model: model, size: size, with: attachments, mask: mask, params: params)
          begin
            connection.post_multipart(url, form)
          ensure
            close_file_parts(form)
          end
        else
          payload = render_image_payload(prompt, model: model, size: size, with: attachments, mask: mask, params: params)
          connection.post(url, payload.to_json)
        end

      parse_image_response(response, model: model)
    end

    # Whether this paint call edits a reference image (vs. generating). The base is
    # conservative — only the editing override (OpenAI) reports true. Providers that
    # support editing override this alongside `validate_paint_inputs!`.
    def editing_image?(with attachments : Attachable?, mask : Source?) : Bool
      false
    end

    # Transcribes an audio file. Mirrors ruby_llm's `Provider#transcribe`.
    # The audio is uploaded as a `multipart/form-data` `file` part (ruby_llm posts a
    # `Faraday::Multipart::FilePart`); the rendered non-file fields ride alongside it.
    def transcribe(audio_file : String, model : String, language : String? = nil,
                   opts : Hash(String, JSON::Any) = {} of String => JSON::Any) : Transcription
      file_part = build_audio_file_part(audio_file)
      payload = render_transcription_payload(file_part, model: model, language: language, opts: opts)
      form = multipart_form(payload, file_field: "file", file: file_part.path)
      response =
        begin
          connection.post_multipart(transcription_url, form)
        ensure
          close_file_parts(form)
        end
      parse_transcription_response(response, model: model)
    end

    # ---- Provider hooks (raising stubs; concrete providers override) ----

    # -- embeddings --

    def embedding_url(model : String) : String
      raise "embedding_url must be implemented by #{self.class.provider_name}"
    end

    def render_embedding_payload(text : TextInput, model : String, dimensions : Int32?) : Hash(String, JSON::Any)
      raise "render_embedding_payload must be implemented by #{self.class.provider_name}"
    end

    def parse_embedding_response(response : Crest::Response, model : String, text : TextInput) : Embedding
      raise "parse_embedding_response must be implemented by #{self.class.provider_name}"
    end

    # -- images --

    def images_url(with attachments : Attachable?, mask : Source?) : String
      raise "images_url must be implemented by #{self.class.provider_name}"
    end

    def render_image_payload(prompt : String, model : String, size : String,
                             with attachments : Attachable?, mask : Source?,
                             params : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      raise "render_image_payload must be implemented by #{self.class.provider_name}"
    end

    def parse_image_response(response : Crest::Response, model : String) : Image
      raise "parse_image_response must be implemented by #{self.class.provider_name}"
    end

    # Renders the multipart form for an image *edit* (the `images/edits` path):
    # the scalar fields plus the reference image file part(s) and optional mask.
    # Only providers that support editing override this (mirrors ruby_llm's
    # `render_edit_payload` + `build_upload_part(s)`).
    def render_image_edit_form(prompt : String, model : String, size : String,
                               with attachments : Attachable?, mask : Source?,
                               params : Hash(String, JSON::Any)) : Hash(String, Crest::ParamsValue)
      raise "render_image_edit_form must be implemented by #{self.class.provider_name}"
    end

    # -- moderation --

    def moderation_url : String
      raise "moderation_url must be implemented by #{self.class.provider_name}"
    end

    def render_moderation_payload(input : TextInput, model : String) : Hash(String, JSON::Any)
      raise "render_moderation_payload must be implemented by #{self.class.provider_name}"
    end

    def parse_moderation_response(response : Crest::Response, model : String) : Moderation
      raise "parse_moderation_response must be implemented by #{self.class.provider_name}"
    end

    # -- transcription --

    def transcription_url : String
      raise "transcription_url must be implemented by #{self.class.provider_name}"
    end

    def render_transcription_payload(file_part : AudioFilePart, model : String,
                                     language : String?, opts : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      raise "render_transcription_payload must be implemented by #{self.class.provider_name}"
    end

    def parse_transcription_response(response : Crest::Response, model : String) : Transcription
      raise "parse_transcription_response must be implemented by #{self.class.provider_name}"
    end

    # Builds the audio file part for a transcription upload. The base implementation
    # is shared across providers (ruby_llm's `Provider#build_audio_file_part`):
    # expand the path, sniff the mime type, carry the basename.
    def build_audio_file_part(audio_file : String) : AudioFilePart
      expanded = File.expand_path(audio_file)
      mime = MimeType.for(name: expanded)
      AudioFilePart.new(path: expanded, mime_type: mime, filename: File.basename(expanded))
    end

    # ---- Multipart helpers (shared; the network half of the upload paths) ----

    # Assembles a crest multipart form from a rendered JSON *payload* (the non-file
    # fields) plus a single file part read from *file* (a path). Scalar JSON values
    # become String form fields; nested objects/arrays are JSON-encoded (matching how
    # ruby_llm sends structured options alongside a file). The file is opened as a
    # `File` so crest preserves its real filename + sniffed MIME in the part header.
    def multipart_form(payload : Hash(String, JSON::Any), file_field : String,
                       file : String) : Hash(String, Crest::ParamsValue)
      form = {} of String => Crest::ParamsValue
      payload.each { |key, value| form[key] = json_to_form_value(value) }
      form[file_field] = File.open(file)
      form
    end

    # Materializes an image *source* into an open `File` upload part. Mirrors
    # ruby_llm's `build_upload_part`: build an `Attachment`, reject non-images, and
    # produce a file part carrying the right filename + MIME. A real file path is
    # opened in place; in-memory / URL content is written to a temp file whose
    # extension drives crest's MIME sniffing.
    def build_upload_part(source : Source) : File
      attachment = Attachment.new(source)
      raise UnsupportedAttachmentError.new(attachment.mime_type) unless attachment.image?

      if source.is_a?(String) && !attachment.url? && File.file?(source)
        File.open(source)
      else
        materialize_upload_part(attachment)
      end
    end

    # Closes any `File` (IO) parts in a multipart form (the upload-part file handles)
    # after the request, so temp files are released. Non-IO scalar fields are skipped.
    def close_file_parts(form : Hash(String, Crest::ParamsValue)) : Nil
      form.each_value do |value|
        next unless value.is_a?(File)

        path = value.path
        value.close
        # Clean up temp files we materialized (under the system temp dir); leave
        # caller-owned paths alone.
        File.delete(path) if path.starts_with?(Dir.tempdir) && File.exists?(path)
      end
    end

    # Converts a rendered JSON field to a crest form value: scalars pass through;
    # objects/arrays are JSON-encoded so structured options survive as form fields.
    private def json_to_form_value(value : JSON::Any) : Crest::ParamsValue
      case raw = value.raw
      when String, Bool, Int64, Int32, Float64, Float32
        raw
      when Nil
        ""
      else
        value.to_json
      end
    end

    # Writes an attachment's bytes to a temp file named with its extension (so crest
    # sniffs the right MIME) and returns the open File.
    private def materialize_upload_part(attachment : Attachment) : File
      ext = attachment.extension
      suffix = ext ? ".#{ext}" : ""
      tmp = File.tempfile("crystal_llm_upload", suffix)
      tmp.write(attachment.content || Bytes.empty)
      tmp.flush
      tmp.rewind
      tmp
    end

    # ---- paint input validation (base; OpenAI overrides) ----

    # ruby_llm's base `validate_paint_inputs!` raises UnsupportedAttachmentError when
    # any with:/mask: is given (only providers that support editing override it).
    def validate_paint_inputs!(with attachments : Attachable?, mask : Source?) : Nil
      return if attachments.nil? && mask.nil?

      raise UnsupportedAttachmentError.new("image reference")
    end
  end

  # ---- Class-method entry points (reopen the data classes) ----

  class Embedding
    # Resolves *model* and dispatches to its provider's `#embed`. Mirrors
    # ruby_llm's `Embedding.embed`. (Instrumentation wrapping is deferred.)
    def self.embed(text : Provider::TextInput, model : String? = nil,
                   provider : String? = nil, assume_model_exists : Bool = false,
                   context : Context? = nil, dimensions : Int32? = nil) : Embedding
      config = context.try(&.config) || CrystalLLM.config
      model_id = model || config.default_embedding_model
      info, provider_instance = CrystalLLM.resolve_provider(model_id, provider, assume_model_exists, config)
      resolved_id = info.id || model_id
      provider_instance.embed(text, model: resolved_id, dimensions: dimensions)
    end
  end

  class Image
    # Resolves *model* and dispatches to its provider's `#paint`. Mirrors
    # ruby_llm's `Image.paint`.
    def self.paint(prompt : String, model : String? = nil, provider : String? = nil,
                   assume_model_exists : Bool = false, size : String = "1024x1024",
                   context : Context? = nil, with attachments : Attachable? = nil,
                   mask : Source? = nil,
                   params : Hash(String, JSON::Any) = {} of String => JSON::Any) : Image
      config = context.try(&.config) || CrystalLLM.config
      model_id = model || config.default_image_model
      info, provider_instance = CrystalLLM.resolve_provider(model_id, provider, assume_model_exists, config)
      resolved_id = info.id || model_id
      provider_instance.paint(prompt, model: resolved_id, size: size, with: attachments, mask: mask, params: params)
    end
  end

  class Moderation
    # Resolves *model* and dispatches to its provider's `#moderate`. Mirrors
    # ruby_llm's `Moderation.moderate`.
    def self.moderate(input : Provider::TextInput, model : String? = nil,
                      provider : String? = nil, assume_model_exists : Bool = false,
                      context : Context? = nil) : Moderation
      config = context.try(&.config) || CrystalLLM.config
      model_id = model || config.default_moderation_model
      info, provider_instance = CrystalLLM.resolve_provider(model_id, provider, assume_model_exists, config)
      resolved_id = info.id || model_id
      provider_instance.moderate(input, model: resolved_id)
    end
  end

  class Transcription
    # Resolves *model* and dispatches to its provider's `#transcribe`. Mirrors
    # ruby_llm's `Transcription.transcribe(audio_file, **kwargs)`; the `**options`
    # splat becomes an explicit `opts` bag (design §11 — no keyword splat survival).
    def self.transcribe(audio_file : String, model : String? = nil,
                        language : String? = nil, provider : String? = nil,
                        assume_model_exists : Bool = false, context : Context? = nil,
                        opts : Hash(String, JSON::Any) = {} of String => JSON::Any) : Transcription
      config = context.try(&.config) || CrystalLLM.config
      model_id = model || config.default_transcription_model
      info, provider_instance = CrystalLLM.resolve_provider(model_id, provider, assume_model_exists, config)
      resolved_id = info.id || model_id
      provider_instance.transcribe(audio_file, model: resolved_id, language: language, opts: opts)
    end
  end

  # Resolves a model id → {Model::Info, Provider instance} against *config*.
  # Shared by the media class methods (the Crystal analog of ruby_llm's
  # `Models.resolve(model, ...) -> [model_info, provider_instance]`, which this
  # port splits: `Models.resolve` returns the Info, `Provider.resolve` the class).
  def self.resolve_provider(model_id : String, provider : String?,
                            assume_exists : Bool, config : Configuration) : {Model::Info, Provider}
    info = Models.resolve(model_id, provider: provider, assume_exists: assume_exists)

    provider_slug = provider || info.provider
    raise ModelNotFoundError.new("Could not determine provider for model #{model_id.inspect}") unless provider_slug

    provider_class = Provider.resolve(provider_slug)
    unless provider_class
      raise ModelNotFoundError.new(
        "Unknown provider: #{provider_slug.inspect}. " \
        "Register it with `CrystalLLM::Provider.register`."
      )
    end

    {info, provider_class.new(config)}
  end

  # ---- Top-level facade shims (mirror ruby_llm.rb's class << self) ----

  # Generate embeddings for *text*. Mirrors `RubyLLM.embed`.
  def self.embed(text : Provider::TextInput, model : String? = nil,
                 provider : String? = nil, assume_model_exists : Bool = false,
                 context : Context? = nil, dimensions : Int32? = nil) : Embedding
    Embedding.embed(text, model: model, provider: provider,
      assume_model_exists: assume_model_exists, context: context, dimensions: dimensions)
  end

  # Generate an image from *prompt*. Mirrors `RubyLLM.paint`.
  def self.paint(prompt : String, model : String? = nil, provider : String? = nil,
                 assume_model_exists : Bool = false, size : String = "1024x1024",
                 context : Context? = nil, with attachments : Attachable? = nil,
                 mask : Source? = nil,
                 params : Hash(String, JSON::Any) = {} of String => JSON::Any) : Image
    Image.paint(prompt, model: model, provider: provider,
      assume_model_exists: assume_model_exists, size: size, context: context,
      with: attachments, mask: mask, params: params)
  end

  # Moderate *input*. Mirrors `RubyLLM.moderate`.
  def self.moderate(input : Provider::TextInput, model : String? = nil,
                    provider : String? = nil, assume_model_exists : Bool = false,
                    context : Context? = nil) : Moderation
    Moderation.moderate(input, model: model, provider: provider,
      assume_model_exists: assume_model_exists, context: context)
  end

  # Transcribe *audio_file*. Mirrors `RubyLLM.transcribe`.
  def self.transcribe(audio_file : String, model : String? = nil,
                      language : String? = nil, provider : String? = nil,
                      assume_model_exists : Bool = false, context : Context? = nil,
                      opts : Hash(String, JSON::Any) = {} of String => JSON::Any) : Transcription
    Transcription.transcribe(audio_file, model: model, language: language,
      provider: provider, assume_model_exists: assume_model_exists,
      context: context, opts: opts)
  end
end
