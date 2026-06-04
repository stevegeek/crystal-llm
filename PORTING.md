# Porting CrystalLLM from ruby_llm

CrystalLLM is a **faithful, version-tracking port** of [ruby_llm](https://github.com/crmne/ruby_llm)
(by Carmine Paolino). The goal: the same public API and names, so ruby_llm's docs
work after a mechanical `RubyLLM → CrystalLLM` swap plus type annotations.

## Upstream reference

- Ported from **ruby_llm v1.15.0**.
- Read-only clone for reference: `../ruby_llm-source/` (`lib/ruby_llm/**`).
- Each ported source file carries a header: `# ported from lib/ruby_llm/<x>.rb @ ruby_llm <version>`.

## Versioning policy

- **Now (pre-parity): `0.x`.** We are building toward the 1.15.0 surface; shipping
  a literal `1.15.0` before the public API matches would mislead.
- **At parity: adopt matching version numbers.** Once the public surface matches a
  given ruby_llm release, CrystalLLM `X.Y.Z` ⇔ ruby_llm `X.Y.Z`.
- Re-porting a new upstream release = `git diff <old-tag>..<new-tag>` on the gem,
  mapped file-by-file. The 1:1 layout keeps this mechanical.

## Layout mapping (ruby_llm → CrystalLLM)

| ruby_llm | CrystalLLM |
|---|---|
| `lib/ruby_llm.rb` | `src/crystal_llm.cr` |
| `lib/ruby_llm/<x>.rb` | `src/crystal_llm/<x>.cr` |
| `lib/ruby_llm/providers/<p>/**` | `src/crystal_llm/providers/<p>/**` |
| `lib/ruby_llm/active_record/**` | (separate shard) `crystal-llm-marten` |
| `models.json` / `aliases.json` | vendored verbatim, re-synced per release |

## Key Crystal divergences

See `docs/specs/2026-06-04-crystal-llm-port-design.md` §11 for the full list. In short:
explicit `param` macro for tools (no runtime signature inference); `ToolResult`
union return; `JSON::Any` on the wire (`alias JSONData = Hash(String, JSON::Any)`);
typed `with_schema(T)`/`ask_as` + `DynamicTool` escape hatches; explicit-context
Agent API; symbols-as-runtime-data → `String`/enum. Crest replaces Faraday; SSE
parsed in-tree.

## Data files

`models.json` / `aliases.json` are **data, not code** — copy verbatim from the gem
and re-sync per release rather than re-deriving.

## Multipart uploads (done) — transcription + image editing

The media pipeline's file-upload paths are **ported** (previously deferred because
`Connection#post` sent a JSON-String body only):

- **`Connection#post_multipart(url, form, headers)`** POSTs `multipart/form-data` via
  crest (`Crest.post(url, form, multipart: true)`), with the same retry + error-map
  wrapping as `#post`. The *form* is `Hash(String, Crest::ParamsValue)`: String scalar
  fields plus IO/`File` values, which crest emits as file parts (sniffing filename +
  MIME). The JSON `#post` path stays for non-file requests (embed / moderate / image
  *generation*).
- **`Provider#transcribe`** routes through `post_multipart`: the audio is added as a
  `file` part (a real `File` opened from `build_audio_file_part`'s path) alongside the
  rendered non-file fields. OpenAI's `render_transcription_payload` no longer emits a
  `file` JSON placeholder — the pipeline owns the part.
- **Image editing** (`paint` with `with:`/`mask:` → `images/edits`) routes through
  `post_multipart`: `render_image_edit_form` builds `image[N]` + `mask` file parts via
  `build_upload_part` (ruby_llm's `build_upload_part(s)`), rejecting non-image sources
  with `UnsupportedAttachmentError`. In-memory / URL sources are materialized to a
  temp file (extension-named so crest sniffs MIME); the pipeline closes/cleans up file
  parts after the request (`close_file_parts`).

Residual deferral: `transcribe`'s `speaker_references` encoding still needs
`Attachment#for_llm` (the attachment-provider data-URL surface) and raises a clear
"deferred" error.

## Foundation review (2026-06-04) — tracked deferrals

A multi-lens review validated the foundation (error, configuration, mime_type).
These items are **deliberately deferred** to a later phase — recorded here so they
read as decisions, not omissions:

- **`Configuration#instrumenter`** — deferred to the instrumentation port (typing it
  `String?` now would be wrong). `model_registry_file` / `model_registry_source` were
  added (pure data); only `instrumenter` waits.
- **`register_provider_options`** → there is no runtime registry method; each provider
  file reopens `class Configuration` and adds `property <provider>_api_key : String? = nil`
  (etc.) at compile time. `Provider.register`'s option-registration call is dropped.
- **`Configuration#[]?(key : String)`** — a macro-over-`instance_vars` string-key reader
  (the Crystal analog of ruby_llm's `@config.send(req)`). Add when the **Connection**
  layer / first provider lands; it powers `ensure_configured!` / `configured?`.
- **`Error#response` is a concrete `Crest::Response?`** for now (correct — don't
  over-abstract pre-Connection). When **Connection** lands, narrow it behind a 2-method
  seam (`status`, `body`) that `Crest::Response` satisfies, or have Connection wrap
  responses before they reach `Error`.
- **`CrystalLLM.logger`** — the memoized top-level logger (`config.logger || ::Log.for(...)`,
  honoring `log_level`/`log_file`) is wired in the **Connection/logging** phase.
- **Secret redaction** — ruby_llm hides `*_key`/`*_secret`/`*_token` from `inspect`.
  `JSON::Serializable` covers *serialization* only, NOT `inspect`/`to_s`. When the first
  api-key property lands, add a redacting `Configuration#inspect`. (Design spec §13 was
  corrected accordingly.)
- **`MimeType.for` replaces marcel** — fixed precedence (magic bytes > filename >
  declared_type > octet-stream), a ~5-format sniff set, and a `Bytes?` first arg (callers
  materialize IO/Path → bytes). The **attachment** port must reproduce ruby_llm's
  two-stage detection (name-first, then re-sniff raw bytes if `octet-stream`) and the
  `audio/x-wav → audio/wav` normalization (verify `.m4a`/`.flac` stdlib-vs-marcel drift).
