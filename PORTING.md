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
parsed in-tree. **Utils.safe_constantize not ported:** Ruby runtime constant lookup
has no Crystal equivalent; its only consumer is ActiveStorage duck-typing (N/A).

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

## Status: FULL PARITY (2026-06-08)

Every item on the roadmap below is now implemented. The full ruby_llm 1.15.0 surface is ported: all 13 providers (chat sync+stream, tool-call loop, tool_prefs, **vision/attachments for every provider**, thinking round-trip, structured output incl. Gemini/Vertex schema rewriter); the media pipeline (embed/paint/moderate/transcribe incl. multipart + `speaker_references`); **provider auth** (Bedrock SigV4 via `awscr-signer`, **VertexAI OAuth2 service-account bearer** via `jwt`, **Azure AAD client-credentials token** — the last exceeds ruby_llm, which only consumes a pre-minted token); instrumentation; cost aggregation (+ String-model-id `normalize_model`); the full Schema DSL; the explicit-context Agent (+ class macros); `Context#chat/embed/paint/moderate/transcribe/connection_for`; `Models.refresh!` (models.dev fetch **+ provider-fetch + merge**). The `crystal-llm-marten` companion adds `acts_as_chat/message/tool_call/model/agent`, the Marten generator commands, `Content::Raw` round-trip, `has_many tool_results`, and **attachment persistence via the optional `marten_storages` shard**.

**Genuine "within the limits of each language" items (NOT gaps — documented divergences):**
- **Agent prompt templates: ported via ECR** (not deferred). ruby_llm's runtime ERB `*.txt.erb` prompt files become compile-time **ECR** templates declared with `prompt_template "name"[, "#{__DIR__}/x.ecr"]` and rendered by `ctx.prompt("name")` in the Context's scope — so a template's `<%= user %>` resolves to the typed `input` getter (type-safe locals, stricter than ruby_llm). **The path is optional**: omit it and it is inferred by convention as `"#{__DIR__}/prompts/<class_snake_path>/<name>.ecr"` rooted at the agent's own source dir (the analog of ruby_llm's project-root `app/prompts/<class>/<name>.txt.erb`). Divergences: the path resolves at COMPILE time (the template ships in the binary; a missing file fails the build, not a runtime `PromptNotFoundError`), and arbitrary `**locals` aren't threaded (declare an `input`). The `instance_exec` runtime-context *blocks* (`instructions`/`tools`/… evaluated against a synthesized receiver) are the genuine Crystal limit — replaced by the typed explicit-context block API (Crystal has no `instance_exec`/`define_method`).
- **Concurrent tool execution: fibers-only** (ruby_llm 1.16.0 / `6695a859` + `6d850443`). `ToolConcurrency` runs a chat's tool calls concurrently, with `Chat#concurrency` + a `concurrency:` kwarg on `with_tool`/`with_tools` and `Configuration#tool_concurrency`. Ruby offers two modes (`:threads`, `:fibers`) and wraps each threaded call in the Rails executor; **Crystal's runtime concurrency IS fibers**, so `MODES = ["fibers"]` is the only mode, `concurrency: true` maps to `"fibers"` (not Ruby's `:threads` default), `"threads"` raises `ArgumentError` naming the available modes, and the Rails-executor wrap is N/A. The whole Ruby `run_with_threads`/`run_with_fibers`/`capture_result`/`run_tool_call`/`rails_executor` helper set collapses into one fiber-spawning `run` over a `Channel`. Public contract preserved: results come back in input order, `on_result` fires per call in COMPLETION order (so `handle_concurrent_tool_calls` appends tool-result messages as each finishes, serialized on the calling fiber), a failing call doesn't stop the others, the first error re-raises only after all complete, and a `Tool::Halt` records `halt_result` without cancelling in-flight calls. Two extra notes: (1) `Chat#normalize_tool_concurrency` treats a **blank/whitespace string as nil (disabled)** — the config DSL strips blank strings to nil for every option, but `Configuration#tool_concurrency : Bool | String` is a non-nilable union that can't carry that treatment, so it normalizes here instead. (2) `with_tools`'s splat is UNTYPED (`*tools`, not `*tools : Tool?`): a type-restricted splat can't be called with zero positional args in Crystal, and `with_tools(concurrency: …)` (no tools) is a supported call; each element is still type-checked at the `with_tool(tool)` call.
- **Index-keyed tool-call streaming** (ruby_llm 1.16.0 / `ff19c933`). Anthropic streams parallel tool calls as interleaved `content_block_start`/`content_block_delta` events distinguished only by an integer content-block `index`; `StreamAccumulator` now keys in-flight calls by a provider "stream key" (`@tool_call_ids_by_index : Hash(String, String)`, mapping stream key → tool-call id) instead of a single global `@latest_tool_call_id`, split into `start_tool_call`/`append_tool_call_fragment`/`find_tool_call` (same names as upstream). Two divergences from Ruby, both forced by Crystal's typed `Hash(String, ToolCall)` (vs Ruby's untyped hash, which can key by `nil` or an `Integer`): (1) Anthropic's `extract_tool_calls` (in `providers/anthropic/streaming.cr`, not `tools.rb`'s `tools.cr` counterpart — see file-location note below) stringifies the block index (`data["index"].to_s`) so the returned hash stays single-keyed; (2) Ruby's `nil` stream key (id-keyed providers with no index concept) becomes `stream_key == ""` in Crystal — the same empty-string-marks-continuation sentinel `ToolCall#id` already used pre-1.16.0, so `find_tool_call("")` falls back to `@latest_tool_call_id` exactly like Ruby's `find_tool_call(nil)`. **File-location divergence**: upstream's fix lives in `providers/anthropic/tools.rb`; this port had already located `extract_tool_calls` in `streaming.cr` (a pre-1.16.0 organizational choice, since it's an SSE-event→Chunk concern), so the parity fix was applied there instead of in `tools.cr`.
- **models.dev metadata: `reasoning_options` + registry resync** (ruby_llm 1.16.0 / `3f27b864`, `48f851db`). `Model::Info#reasoning_options` normalizes `data["reasoning_options"]` (preferred) or `metadata["reasoning_options"]` into `Array(Hash(String, JSON::Any))` — ruby_llm's `transform_keys(&:to_sym)` has no Crystal analogue (no runtime symbols), so keys stay String throughout; `#reasoning_option(type)`/`#reasoning_option_values(type)` mirror upstream's finder + `Array(...&.fetch(:values, nil))` (the latter as `[] of String` on a missing option/key). `#initialize` `.dup`s `@metadata` before `store_reasoning_options_metadata` mutates it in place (delete + re-set), matching ruby_llm's `data[:metadata]&.dup` — needed because Crystal's `JSON::Any#as_h` returns the underlying Hash by reference, not a copy, so skipping the dup would corrupt a caller's still-held parsed JSON. `models.cr` gained the matching upstream pieces: `xai` joined `MODELS_DEV_PROVIDER_MAP`; `MODELS_DEV_INPUT_MODALITIES`/`MODELS_DEV_OUTPUT_MODALITIES` intersect (`&`, Ruby and Crystal agree on set-intersection-preserving-receiver-order semantics) each side of `normalize_models_dev_modalities` against the models.dev-owned vocab; `models_dev_capabilities` grants `"reasoning"` when EITHER `reasoning` OR `reasoning_options` is present; `add_provider_metadata`'s capability union now strips `MODELS_DEV_AUTHORITY_CAPABILITIES` (function_calling/structured_output/reasoning/vision) from the PROVIDER side unless models.dev also grants them — models.dev is the authority for those four, so a stale/wrong provider-side claim no longer survives the merge (this is the actual bug upstream fixes, #782/#766). Also (`48f851db`): models.dev `created_at` now goes through Task 1's `Utils.iso_date_prefix_to_utc_midnight_string` (handles `YYYY-MM-DD`/`YYYY-MM`/`YYYY`) instead of a bare `"#{date} 00:00:00 UTC"` concat, which left month/year-only dates unparseable by `Info#to_time`. DeepSeek's `Capabilities` gained `context_window_for`/`max_tokens_for` (fixed constants) + `critical_capabilities_for`/`pricing_for` (model-id-keyed, `deepseek-v4-pro` gets `PRO_PRICES`). xAI's `Providers::XAI` dropped the hard-coded `IMAGE_MODELS`/`VISION_MODELS`/`REASONING_MODELS` id lists (vision/reasoning/function_calling/structured_output for chat models now come from models.dev via the provider-map addition above); the live `list_models` parse now only self-classifies image/video-*generation* models via `image_model?`/`video_model?` regex predicates (`\Agrok-(?:2-)?imagine-image`/`-video`, plus the legacy `grok-2-image-1212` id), giving every other model a bare `["streaming"]` capability.
- **Anthropic adaptive thinking + content formatting fixes** (ruby_llm 1.16.0 / `3f27b864` anthropic part, `a6a02653`, `a66e7005`). `Providers::Anthropic#build_thinking_payload(thinking, model)` (in `providers/anthropic/chat.cr`) now consults `Model::Info#reasoning_option(type)` instead of unconditionally requiring a budget: a budget on a model whose registry entry has the `budget_tokens` reasoning option → `enabled_thinking_payload` (`{thinking:{type:"enabled",budget_tokens:}}`); no budget + an effort (not `"none"`) on a model with the `effort` option → `adaptive_thinking_payload` (`{thinking:{type:"adaptive"},output_config:{effort:}}`); `effort == "none"` disables thinking outright; a budget/effort requested on a model that doesn't advertise the matching option raises `ArgumentError` naming the model id; no budget and no usable effort raises `ArgumentError` ("Anthropic adaptive thinking requires an effort"). `add_thinking_fields`/`resolve_effort`/`resolve_budget` are ported under the same names as upstream. The adaptive-thinking `output_config` and the schema-driven `output_config` (`build_output_config`) now MERGE (`Utils.deep_merge`, factored into a shared `merge_output_config` helper) instead of the schema clobbering thinking's `effort` key. Separately, `format_tool_call_message` (this port's location for upstream `tools.rb`'s `format_tool_call` — see the file-location divergence noted above) was stringifying `Content` via `.to_s` before formatting, silently dropping attachments on assistant tool-call messages; it now routes through the already-ported `append_formatted_content` (which concats an `Array` of formatted blocks rather than nesting them), matching `format_basic_message`, which was already correct. `Content#empty?` (attachments empty + text nil/blank) landed and is used by this exact guard (`unless content.empty?`) instead of a raw `.to_s`/nil check. `Content#add_attachment`/`build_attachment` now accept an existing `Attachment` and reuse it as-is (only re-wrapping via `Attachment.new(source.source, filename:)` when a NEW filename is given) — `add_attachment`'s parameter widened from `Source` to `Source | Attachment`; the `Source` alias itself (and the broader `Attachable` used by `Chat#ask`/`Content.new`) is untouched, so this is reachable via a direct `add_attachment(existing_attachment)` call, not yet via the public multi-source constructor path. `ErrorMiddleware::CONTEXT_LENGTH_PATTERNS` gained `/prompt is too long/i` so Anthropic's `"prompt is too long: N tokens > max maximum"` 400 maps to `ContextLengthExceededError` instead of `BadRequestError`.
- `railtie.rb` auto-wiring → N/A; Marten uses explicit `include` macros.
- Live-cloud verification needs real credentials (the structure is unit-tested offline; the spec suites BLOCK external network via `CRYSTAL_LLM_BLOCK_EXTERNAL_NETWORK`). Run the TaskPilot POC with a real key to exercise it end-to-end.

The original prioritized roadmap (kept for history):

## Path to full parity — roadmap (2026-06-04 audit)

A systematic parity audit (172 features) put CrystalLLM at **~80–85% functional parity** with ruby_llm 1.15.0: the core paths (chat ask/complete sync+stream, the tool-call loop, primitive/object/array Schemas, raw structured output, the facade, OpenAI/Anthropic/Gemini chat, base Configuration) are ported and working. **All remaining work below is now DONE (see the Status block above).**

**Critical (blocks real use — "looks ported but doesn't work"):**
1. **Provider auth** — ✅ **Bedrock DONE.** SigV4 is now threaded into every request via a `Provider#sign_headers(method, url, body)` hook (default `{}`), merged by the sync/stream/list pipeline (`provider_completion.cr` + `streaming.cr`). Bedrock overrides it (`providers/bedrock/auth.cr`) to compute SigV4 with the `awscr-signer` shard: it builds an `HTTP::Request` mirroring the crest call, sets `Host`, signs (service "bedrock", `bedrock_region`/`bedrock_api_key`/`bedrock_secret_key`; `bedrock_session_token` → `amz_security_token:`, so it lands in SignedHeaders), and lifts `Authorization`/`X-Amz-Date`/`X-Amz-Content-Sha256`(+`X-Amz-Security-Token`) back out. `models_url` returns the FULL control-plane URL (`https://bedrock.<region>.amazonaws.com/foundation-models`) so the list GET routes + signs against the control plane. Unit-tested structurally (no live AWS). **VertexAI: ✅ DONE** — `providers/vertexai/auth.cr` mints an OAuth2 bearer from a service-account key (builds + signs an RS256 JWT assertion via the `jwt` shard, exchanges it at the jwt-bearer grant endpoint, caches until `exp`). **Azure: ✅ DONE** — `providers/azure.cr` consumes a pre-minted `azure_ai_auth_token` (ruby_llm's only path) AND adds an AAD client-credentials flow (mints + caches a bearer when tenant/client id/secret are set — a divergence that EXCEEDS ruby_llm 1.15.0).
2. **Thinking round-trip** — ✅ **DONE.** `Message#thinking` (a `Thinking` value: text + signature) + the `thinking:` constructor kwarg + `Message#to_h` (incl. `thinking`/`thinking_signature`) landed, with the same field on `Chunk`. Inbound thinking is now attached instead of dropped: Anthropic (thinking/redacted_thinking blocks + streamed thinking_delta/signature_delta), Gemini (thought parts + thoughtSignature, sync + stream), OpenAI base (thinking content blocks + `reasoning_content`/`reasoning` keys, sync + stream — covers Mistral inbound), and OpenRouter (`reasoning` String / `reasoning_details` array via overridden extract helpers). `StreamAccumulator#append_thinking_from_chunk` folds streamed thinking and sets it on the final Message. Outbound: Anthropic prepends thinking/redacted_thinking blocks to assistant messages when thinking is enabled; OpenAI base re-emits `reasoning`/`reasoning_content`/`reasoning_signature`; OpenRouter emits `reasoning_details`; Mistral emits thinking content blocks. Residual: full structural `content`/`tool_calls` serialization in `Message#to_h` stays a crystal-llm-marten persistence concern.

**High:**
3. **Streaming error handling** — ✅ **DONE.** Generic SSE error mapping (`raise_if_stream_error` → `parse_streaming_error` → `ErrorMiddleware`) and the non-200 stream-start `map_error` path both landed. Bedrock binary-eventstream decode now landed too: `Bedrock#stream_response` overrides the SSE mixin to read `application/vnd.amazon.eventstream` frames off `body_io` (`decode_event_stream`/`read_event_frame` — big-endian total/headers len, prelude CRC32, payload, message CRC32 via `Digest::CRC32`), peels the base64 `{"bytes": …}` envelope (`decode_event_payload`), raises mapped errors for exception/`type:error` events (`stream_error_status`), and feeds the rest to `build_chunk`. CRC/truncation failures raise `Bedrock::EventStreamError`. *(M)*
4. **tool_prefs forwarding** — ✅ **DONE.** `Chat#complete_once` now passes `@tool_prefs` through `Provider#complete` → `render_payload` (a new `tool_prefs : Hash(String, String?)? = nil` param on the base hook + every provider override + both `complete` overloads). Each provider emits its wire-specific control: OpenAI-family `tool_choice` (`"auto"/"none"/"required"`/`{type:function,function:{name}}`) + `parallel_tool_calls` (`calls == "many"`); Anthropic `tool_choice {type: auto|none|any|tool, name?, disable_parallel_tool_use?}` (`calls == "one"`); Gemini/Vertex `toolConfig.functionCallingConfig` (mode AUTO/NONE/ANY + allowedFunctionNames; no parallel control); Bedrock `toolConfig.toolChoice` (`{auto:{}}`/nil/`{any:{}}`/`{tool:{name}}`); Mistral inherits OpenAI then maps required→"any"/single-tool normalization. The `:calls` per-turn limit still drives the forced-choice reset in chat.cr. Tested per provider + an end-to-end Chat threading/reset test.
5. **Vision/attachments parity + Gemini/Vertex structured-output schema** — Bedrock/Vertex emit no image blocks. **Gemini/Vertex structured-output schema: DONE.** The recursive GeminiSchema rewriter (uppercase TYPE values STRING/NUMBER/INTEGER/BOOLEAN/ARRAY/OBJECT, propertyOrdering, nullable, anyOf `[T,null]` collapse, `$ref`/`$defs`/`definitions` resolution-or-strip with override-merge + cycle guard, strip strict/additionalProperties) plus the `responseJsonSchema`-vs-`responseSchema` version gate (Gemini >= 2.5 -> cleaned raw schema; older -> rewritten) live in `providers/gemini/schema.cr` (`Providers::GeminiSchema` + `GeminiVersion`), SHARED by both the native Gemini and VertexAI providers via `structured_output_config(schema, model)`. Tested: nested object+array+enum+nullable+anyOf rewrite, $ref/$defs (+cycle), both gate branches, for Gemini and Vertex. **Vision/attachment blocks: DONE.** `providers/bedrock/media.cr` (`Bedrock::Media`) emits Converse `image`/`document` blocks (format + base64 bytes, doc-name sanitize + per-payload de-dup via `@used_document_names`), wired through `bedrock/chat.cr#render_attachment_blocks`. `providers/vertexai/media.cr` now emits Gemini-style `inline_data` parts (text-file -> `{text}`, image/audio/pdf/video -> `{inline_data}`, document/unknown -> UnsupportedAttachmentError) instead of raising NotImplementedError. DeepSeek/xAI attachment **gating** is ported as overridable `format_content` hooks on the OpenAI base: DeepSeek gates ALL media off (text-only); xAI permits images only (documents/audio -> UnsupportedAttachmentError). Tested in `spec/providers/attachment_media_spec.cr`. *(M)*

**Medium:** 6. Instrumentation — ✅ **DONE.** `src/crystal_llm/instrumentation.cr` ports ruby_llm's `Instrumentation` module as `CrystalLLM::Instrumentation.instrument(name, payload, config) { |event| ... }` (surfaced on the facade as `CrystalLLM.instrument`). The ActiveSupport::Notifications seam is reified as an overridable `CrystalLLM::Instrumenter` base (concrete, not abstract — Crystal can't `abstract def` a free `forall T` return; the default `instrument` just yields, so a bare instance is a transparent instrumenter) plus a bundled `ProcInstrumenter`. `Configuration#instrumenter : Instrumenter? = nil` is added by reopening Configuration in instrumentation.cr (late-require pattern); `nil` = no-op. Payloads are `Hash(String, Instrumentation::Value)` (an explicit union of the live objects ruby_llm stuffs in — Chat/Message/Tool/ToolCall/token counts/etc; symbol keys → String). `Chat#complete` now wraps `complete_once` in `instrument_completion` (emits `chat.crystal_llm` with model/messages/tools/options + response-side token counts), and `execute_tool` wraps the call in `instrument_tool_call` (`tool_call.crystal_llm` + result/result_content). Event-name suffix renamed `ruby_llm` → `crystal_llm`. ruby_llm's `build_payload(**attributes)` kwarg-merge has no Crystal analogue (no runtime kwargs) — callers build the payload up-front. Tested in `spec/instrumentation_spec.cr` (configured recorder sees chat + tool_call events with expected keys; nil instrumenter is a transparent no-op). 7. Cost aggregation (`Chat#cost`/`Message#cost`/`Image#cost`). 8. Marten persistence completion (`acts_as_model`, full message persistence incl. thinking/content_raw/attachments). 9. Schema validator + conditionals (`any_of`/`one_of`/`define`/`$ref`). 10. Agent class macros (headers/schema/thinking/context).

**Low:** 11. typed `ask_as(T)` + legacy callbacks. 12. Models `refresh!`/json persistence. 13. Marten generators. 14. Transcription `speaker_references` + `Attachment#for_llm`.

**Quick wins (existing infra, just wiring):** ~~tool_prefs → `render_payload`~~ (DONE); non-200 guard on the stream path → `map_error`; ~~thread the done Bedrock SigV4 into requests~~ (DONE); `Image#to_blob` URL branch via `Connection.basic_get`; `CrystalLLM.deprecator` facade accessor; `Chat#cost`/`Message#cost` over the existing `Cost.aggregate` + Models registry.

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
  **Update (ruby_llm 1.16.0 / `93a47e3b`):** ruby_llm's `option` DSL now strips blank
  strings to nil in every setter. Since Crystal has no shared setter hook, every
  `String?` option (system-level in `configuration.cr` and provider-added) uses the
  `private macro nilable_string_option(name)` defined once in `configuration.cr`
  instead of bare `property foo : String? = nil` — it expands to an identical getter
  plus a setter that maps a blank/whitespace-only string to nil. Private macros ARE
  visible across files that reopen the same class (verified: no file-scoping like
  private top-level defs), so every provider file calls it the same way. Non-nilable
  and non-String options (Bool, Int32, Float64, …) are untouched — they can't hold
  blank-as-nil.
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
