# CrystalLLM — a delightful Crystal interface to modern AI language models.
#
# A faithful port of ruby_llm (crmne/ruby_llm). The public API mirrors the gem:
# `CrystalLLM.chat`, `.embed`, `.paint`, `.transcribe`, `.moderate`,
# `.configure`, `.context`, `.models`. See docs/specs for the porting design.
require "./crystal_llm/version"
require "./crystal_llm/sse"
require "./crystal_llm/model/modalities"
require "./crystal_llm/model/pricing_category"
require "./crystal_llm/model/pricing_tier"
require "./crystal_llm/error"
require "./crystal_llm/error_middleware"
require "./crystal_llm/configuration"
require "./crystal_llm/mime_type"
require "./crystal_llm/attachment"
require "./crystal_llm/content"
require "./crystal_llm/tokens"
require "./crystal_llm/tool_call"
require "./crystal_llm/message"
require "./crystal_llm/chunk"
require "./crystal_llm/thinking"
require "./crystal_llm/deprecator"
require "./crystal_llm/context"
require "./crystal_llm/stream_accumulator"
require "./crystal_llm/schema"
require "./crystal_llm/model/pricing"
require "./crystal_llm/model/info"
require "./crystal_llm/cost"
require "./crystal_llm/model"
require "./crystal_llm/tool"
require "./crystal_llm/embedding"
require "./crystal_llm/image"
require "./crystal_llm/moderation"
require "./crystal_llm/transcription"
require "./crystal_llm/utils"
require "./crystal_llm/connection"
require "./crystal_llm/streaming"
require "./crystal_llm/provider"
require "./crystal_llm/models"
require "./crystal_llm/provider_completion"
require "./crystal_llm/provider_media"
require "./crystal_llm/providers/openai"
require "./crystal_llm/providers/anthropic"
require "./crystal_llm/providers/gemini"
require "./crystal_llm/providers/deepseek"
require "./crystal_llm/providers/mistral"
require "./crystal_llm/providers/ollama"
require "./crystal_llm/providers/openrouter"
require "./crystal_llm/providers/perplexity"
require "./crystal_llm/providers/gpustack"
require "./crystal_llm/providers/xai"
require "./crystal_llm/providers/azure"
require "./crystal_llm/providers/bedrock"
require "./crystal_llm/providers/vertexai"
require "./crystal_llm/chat"
require "./crystal_llm/agent"
require "./crystal_llm/facade"

module CrystalLLM
  @@config : Configuration? = nil
  @@logger : ::Log? = nil

  # The global configuration. `CrystalLLM.config.openai_api_key = "..."`.
  def self.config : Configuration
    @@config ||= Configuration.new
  end

  # Yields the global configuration for block-style setup.
  def self.configure(&) : Nil
    yield config
  end

  # The memoized logger: the configured `Log`, or a default `CrystalLLM` logger.
  def self.logger : ::Log
    @@logger ||= config.logger || ::Log.for("CrystalLLM")
  end
end
