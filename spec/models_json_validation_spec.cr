require "./spec_helper"

# Ports ruby_llm's models_json_validation_spec.rb (@ 1.15.0).
#
# Validates the integrity of the compile-time-embedded models.json registry.
# Offline-safe: all assertions operate on `CrystalLLM::Models.instance.all`,
# which reads the JSON baked into the binary — no network calls.
module CrystalLLM
  describe "models.json integrity" do
    models = Models.instance.all

    it "contains at least 1000 models" do
      models.size.should be >= 1000
    end

    it "every model has a non-empty id" do
      bad = models.select { |info| info.id.nil? || info.id.to_s.empty? }
      bad.should be_empty, "models with missing id: #{bad.map(&.to_h.to_s).first(5)}"
    end

    it "every model has a non-empty provider" do
      bad = models.select { |info| info.provider.nil? || info.provider.to_s.empty? }
      bad.should be_empty, "models with missing provider: #{bad.map(&.to_h.to_s).first(5)}"
    end

    it "capabilities is an Array of Strings (never a raw Hash or nil)" do
      models.each do |info|
        info.capabilities.should be_a(Array(String)),
          "#{info.id} (#{info.provider}) has capabilities: #{info.capabilities.inspect}"
      end
    end

    it "every model's modalities.input is an Array of Strings" do
      models.each do |info|
        info.modalities.input.should be_a(Array(String)),
          "#{info.id} (#{info.provider}) has bad modalities.input: #{info.modalities.input.inspect}"
      end
    end

    it "every model's modalities.output is an Array of Strings" do
      models.each do |info|
        info.modalities.output.should be_a(Array(String)),
          "#{info.id} (#{info.provider}) has bad modalities.output: #{info.modalities.output.inspect}"
      end
    end

    it "context_window is nil or a non-negative integer" do
      models.each do |info|
        cw = info.context_window
        next if cw.nil?
        cw.should be >= 0,
          "#{info.id} (#{info.provider}) has negative context_window: #{cw}"
      end
    end

    it "max_output_tokens is nil or a non-negative integer" do
      models.each do |info|
        mo = info.max_output_tokens
        next if mo.nil?
        mo.should be >= 0,
          "#{info.id} (#{info.provider}) has negative max_output_tokens: #{mo}"
      end
    end

    it "input_price_per_million is nil or non-negative" do
      models.each do |info|
        price = info.input_price_per_million
        next if price.nil?
        price.should be >= 0.0,
          "#{info.id} (#{info.provider}) has negative input price: #{price}"
      end
    end

    it "output_price_per_million is nil or non-negative" do
      models.each do |info|
        price = info.output_price_per_million
        next if price.nil?
        price.should be >= 0.0,
          "#{info.id} (#{info.provider}) has negative output price: #{price}"
      end
    end

    it "provider values are from the known set" do
      known_providers = %w[
        openai anthropic gemini vertexai bedrock openrouter deepseek mistral
        perplexity xai azure ollama gpustack
      ]
      unknown = models.reject { |info| known_providers.includes?(info.provider.to_s) }
      unknown.should be_empty,
        "models with unknown provider: #{unknown.map { |info| "#{info.id}@#{info.provider}" }.first(5)}"
    end

    it "no two models share the same (provider, id) pair" do
      pairs = models.map { |info| "#{info.provider}:#{info.id}" }
      duplicates = pairs.tally.select { |_key, count| count > 1 }.keys
      duplicates.should be_empty, "duplicate provider:id pairs: #{duplicates.first(5)}"
    end

    it "created_at parses to a Time when present" do
      models.each do |info|
        next if info.created_at.nil?
        info.created_at.should be_a(Time),
          "#{info.id} (#{info.provider}) created_at is not a Time: #{info.created_at.inspect}"
      end
    end
  end
end
