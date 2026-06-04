# ported from lib/ruby_llm/providers/gpustack.rb @ ruby_llm 1.15.0
#
# GPUStack embedding hooks.
#
# In ruby_llm there is NO `providers/gpustack/embeddings.rb`: `GPUStack < OpenAI`
# (see gpustack.rb) includes only `GPUStack::{Chat,Models,Media}` and therefore
# inherits the OpenAI `Embeddings` mixin (`embedding_url` / `render_embedding_payload`
# / `parse_embedding_response`) *verbatim*. GPUStack speaks the OpenAI-compatible
# `/v1/embeddings` wire shape, so no override is needed.
#
# The faithful Crystal port mirrors that exactly: `CrystalLLM::Providers::GPUStack`
# subclasses `CrystalLLM::Providers::OpenAI` (providers/gpustack.cr), so it already
# inherits the three OpenAI embedding hooks defined in providers/openai/embeddings.cr.
# This file adds NO new method definitions — it exists so the gpustack media surface
# can be required in isolation (it pulls in providers/openai/embeddings.cr, which
# carries the inherited hooks) and so the inheritance decision is documented next to
# its peers (the way each gpustack/<kind>.cr file would be), matching how the OpenAI
# port splits its media hooks into providers/openai/<kind>.cr files.
#
# == Divergences from ruby_llm (documented + returned) ==
#
# * No gpustack/embeddings.rb exists upstream; the OpenAI behavior is inherited, not
#   re-declared. The Crystal port keeps a (no-op-override) file purely as the
#   require-/documentation- anchor for the gpustack embeddings surface. The actual
#   hook bodies live in (and are inherited from) providers/openai/embeddings.cr:
#     - embedding_url(model)               => "embeddings"
#     - render_embedding_payload(...)      => {model, input, dimensions?} (compact)
#     - parse_embedding_response(...)      => flatten-single-vector rule (1 row AND
#                                             input not Array => flat vector)
# * The OpenAI helpers `text_to_json` / `extract_vector` are `private` on
#   `Providers::OpenAI`; GPUStack inherits them through the class hierarchy, so the
#   inherited `render_embedding_payload` / `parse_embedding_response` work unchanged
#   on a `GPUStack` instance.
#
# == DEFERRED (returned) ==
#
# * Nothing additional here: embeddings are fully covered by the inherited OpenAI
#   hooks. (Image / moderation / transcription remain deferred for GPUStack — the
#   task scope is embeddings only, and upstream gpustack ships no overrides for
#   those either; they would likewise inherit OpenAI's.)
require "json"
require "../gpustack"
require "../openai/embeddings"

module CrystalLLM
  module Providers
    # Reopen GPUStack solely to anchor the gpustack embedding surface. All three
    # embedding hooks are inherited unchanged from Providers::OpenAI (see header).
    class GPUStack < OpenAI
    end
  end
end
