# ported from lib/ruby_llm/chunk.rb @ ruby_llm 1.15.0
require "./message"

module CrystalLLM
  # A streaming delta. Structurally a Message; the StreamAccumulator folds chunks
  # into the final Message.
  class Chunk < Message
  end
end
