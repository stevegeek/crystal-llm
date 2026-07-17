# Safeguard: make any real external (non-localhost) HTTP request raise loudly so a
# test can never silently hit a live provider API (e.g. api.openai.com). The
# connection-layer specs' in-process servers bind to 127.0.0.1 and stay allowed.
ENV["CRYSTAL_LLM_BLOCK_EXTERNAL_NETWORK"] = "1"

require "spec"
require "../src/crystal_llm"
