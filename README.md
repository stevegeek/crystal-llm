# CrystalLLM

One beautiful Crystal API for GPT, Claude, Gemini, and more.

CrystalLLM is a faithful Crystal port of [**ruby_llm**](https://github.com/crmne/ruby_llm)
by Carmine Paolino. It mirrors ruby_llm's public API and tracks its versions, so the
[ruby_llm documentation](https://rubyllm.com) largely applies after a mechanical
`RubyLLM → CrystalLLM` swap plus Crystal type annotations.

> **Status: early development (`0.x`).** The shard is being built out provider-by-provider
> toward parity with ruby_llm 1.15.0. See [`PORTING.md`](PORTING.md) for the plan and the
> versioning policy.

## Goals

```crystal
chat = CrystalLLM.chat(model: "gpt-4o")
response = chat.ask("What's the best way to learn Crystal?")
puts response.content
```

Same chainable builder, tools, streaming, structured output, embeddings, image
generation, transcription, moderation, and (eventually) a `crystal-llm-marten`
companion shard for persistence — see `docs/specs/` for the design.

## Development

```bash
script/shards install   # fetch dependencies (wrapper sets CRYSTAL_LIBRARY_PATH)
script/spec             # run the spec suite
script/cr tool format   # format
```

The `script/*` wrappers export `CRYSTAL_LIBRARY_PATH` to work around the asdf-0.18
issue; use them instead of bare `crystal`/`shards`.

## Credit & license

A port of ruby_llm (MIT, © Carmine Paolino). CrystalLLM is MIT-licensed; see
[`LICENSE`](LICENSE).
