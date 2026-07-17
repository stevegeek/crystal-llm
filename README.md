# CrystalLLM

**A faithful Crystal port of [ruby_llm](https://github.com/crmne/ruby_llm) by Carmine Paolino.**

CrystalLLM mirrors ruby_llm's public API and tracks its version numbers, so the
[ruby_llm documentation](https://rubyllm.com) largely applies after a mechanical
`RubyLLM → CrystalLLM` swap plus Crystal type annotations. If you know ruby_llm,
you already know CrystalLLM.

> **Status: full parity with ruby_llm 1.16.0.**
> Core paths (chat, tools, streaming, structured output, embeddings, image generation,
> transcription, moderation) are ported and working across all 13 providers.
> \* One narrow inbound gap: VertexAI doesn't yet parse attachments back out of a
> response (inline media collapses to text) — see [`PORTING.md`](PORTING.md).
> See [`PORTING.md`](PORTING.md) for the roadmap and versioning policy.

---

## Attribution

CrystalLLM is a derivative work of **ruby_llm** (MIT, © 2025 Carmine Paolino).
All credit for the API design, provider implementations, model registry data files,
and architectural vision belongs to Carmine Paolino and the ruby_llm contributors.

- **Original project:** https://github.com/crmne/ruby_llm
- **Original documentation:** https://rubyllm.com
- **Ported from:** ruby_llm 1.16.0

---

## Installation

Add to `shard.yml`:

```yaml
dependencies:
  crystal_llm:
    github: stevegeek/crystal-llm
```

Then `shards install` (or `script/shards install` in the workspace, which sets
`CRYSTAL_LIBRARY_PATH` for the asdf-0.18 workaround).

Configure your API keys:

```crystal
CrystalLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  # config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  # config.gemini_api_key    = ENV["GEMINI_API_KEY"]
end
```

---

## Show me the code

```crystal
# Just ask questions
chat = CrystalLLM.chat(model: "gpt-4o")
response = chat.ask("What's the best way to learn Crystal?")
puts response.content
```

```crystal
# Stream responses
chat.ask("Tell me a story about Crystal") do |chunk|
  print chunk.content
end
```

```crystal
# Attach files (images, audio, PDFs, code)
chat.ask("What's in this image?", with: "screenshot.png")
chat.ask("Summarize this document", with: "contract.pdf")
```

```crystal
# Let AI use your code — define a tool with the `param` macro
class Weather < CrystalLLM::Tool
  description "Get current weather for a location"

  param :latitude,  Float64, "Latitude"
  param :longitude, Float64, "Longitude"

  def execute : CrystalLLM::ToolResult
    url = "https://api.open-meteo.com/v1/forecast?latitude=#{@latitude}&longitude=#{@longitude}&current=temperature_2m"
    Crest.get(url).body
  end
end

chat.with_tool(Weather).ask("What's the weather in Berlin?")
```

```crystal
# Get structured output with a typed schema
class Product < CrystalLLM::Schema
  string :name
  number :price
  array :features { string }
end

response = chat.with_schema(Product).ask("Analyze this product", with: "product.pdf")
product = response.as(Product)
```

```crystal
# Generate images
CrystalLLM.paint("a sunset over mountains in watercolor style")
```

```crystal
# Create embeddings
CrystalLLM.embed("Crystal is fast and expressive")
```

```crystal
# Transcribe audio
CrystalLLM.transcribe("meeting.wav")
```

```crystal
# Moderate content
CrystalLLM.moderate("Check if this text is safe")
```

```crystal
# Build an agent with instructions and tools
class WeatherAssistant < CrystalLLM::Agent
  model "gpt-4o"
  instructions "Be concise and always use tools for weather."
  tools Weather
end

WeatherAssistant.new.ask("What's the weather in Berlin?")
```

---

## Features

- **Chat:** Conversational AI with `CrystalLLM.chat`
- **Vision:** Analyze images and videos
- **Audio:** Transcribe speech with `CrystalLLM.transcribe`
- **Documents:** Extract from PDFs, CSVs, JSON, any file type
- **Image generation:** Create images with `CrystalLLM.paint`
- **Embeddings:** Generate embeddings with `CrystalLLM.embed`
- **Moderation:** Content safety with `CrystalLLM.moderate`
- **Tools:** Let AI call your Crystal code (explicit `param` macro)
- **Agents:** Reusable assistants with `CrystalLLM::Agent`
- **Structured output:** `with_schema(T)` / `ask_as(T)` + `DynamicTool` escape hatches
- **Streaming:** Real-time responses with blocks (in-tree SSE parser)
- **Extended thinking:** Persist and inspect model deliberation (`Message#thinking`)
- **Model registry:** 800+ models with capability detection (vendored `models.json`)
- **Instrumentation:** Event hooks via `CrystalLLM.instrument` (`Instrumenter` protocol)
- **Marten persistence:** See the [`crystal_llm_marten`](https://github.com/stevegeek/crystal-llm-marten) companion shard

---

## Supported providers

OpenAI, xAI, Anthropic, Gemini, VertexAI, Bedrock (SigV4), DeepSeek, Mistral,
Ollama, OpenRouter, Perplexity, GPUStack, and any OpenAI-compatible API —
the same 13 providers as ruby_llm 1.16.0.

---

## Differences from ruby_llm

Because Crystal is statically typed and has no runtime metaprogramming, a handful
of idioms differ from the Ruby original. The API names and shapes are identical
wherever possible.

| ruby_llm (Ruby) | CrystalLLM (Crystal) |
|---|---|
| Tool params inferred from method signature at runtime | Explicit `param :name, Type, "description"` macro required |
| `execute` returns anything | `execute : CrystalLLM::ToolResult` (explicit union return type) |
| JSON data as `Hash` / Ruby objects | `alias JSONData = Hash(String, JSON::Any)` on the wire |
| `chat.ask_as(ProductSchema)` returns inferred Ruby type | `with_schema(T)` + `ask_as(T)` with explicit Crystal type param |
| Untyped `DynamicTool`-like patterns via `method_missing` | Explicit `DynamicTool` class for runtime-described tools |
| `Agent` context via `instance_exec` / ERB | Explicit-context Agent API (no `instance_exec`) |
| Symbols used as runtime data (e.g. roles, event names) | `String` or enums; symbols are compile-time only |
| Faraday HTTP client | [Crest](https://github.com/mamantoha/crest) HTTP client |
| SSE via server-sent-events gem | In-tree SSE parser |
| AWS auth via aws-sdk gem | [awscr-signer](https://github.com/taylorfinnell/awscr-signer) shard |
| JWT via jwt gem | [jwt](https://github.com/crystal-community/jwt) shard (VertexAI) |

For the complete list of divergences and deferred items, see [`PORTING.md`](PORTING.md).
Because the public API mirrors ruby_llm's, the [ruby_llm docs](https://rubyllm.com)
are your primary reference — just swap `RubyLLM` → `CrystalLLM` and add Crystal
type annotations where required.

---

## Version / parity

- **At parity:** CrystalLLM adopts matching version numbers. The public surface
  now matches ruby_llm 1.16.0, so `crystal_llm` is versioned `1.16.0`; future
  releases will track `ruby_llm X.Y.Z` the same way.

---

## Marten persistence

For persisting chats, messages, and tool calls in a [Marten](https://martenframework.com)
web application, see the companion shard
[`crystal_llm_marten`](https://github.com/stevegeek/crystal-llm-marten) —
the Crystal analog of ruby_llm's `acts_as_chat` / `acts_as_message` /
`acts_as_tool_call` ActiveRecord integration.

---

## Development

```bash
script/shards install   # fetch dependencies (sets CRYSTAL_LIBRARY_PATH for asdf-0.18)
script/spec             # run the spec suite
script/cr tool format   # format
```

Use the `script/*` wrappers instead of bare `crystal`/`shards` — they export
`CRYSTAL_LIBRARY_PATH` to work around the asdf-0.18 issue.

---

## License

MIT. See [`LICENSE`](LICENSE).

This project is a Crystal port of [ruby_llm](https://github.com/crmne/ruby_llm)
(MIT, © 2025 Carmine Paolino). All original work is © Carmine Paolino and the
ruby_llm contributors. The Crystal port is © 2026 the CrystalLLM authors.
