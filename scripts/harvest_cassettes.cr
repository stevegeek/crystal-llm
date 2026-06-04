# Dev tool (not part of the shard). Harvests REAL provider response bodies from
# ruby_llm's VCR cassettes into a classified fixture library, so our parse/stub
# specs can run against actual recorded provider output (no API keys, no network).
#
# We do NOT replay cassettes (VCR request-matching fails — our render_payload
# diverges slightly from Ruby's). We only mine the response bodies.
#
#   crystal run scripts/harvest_cassettes.cr -- <cassettes_dir> <out_dir>
require "yaml"
require "json"
require "file_utils"

CASSETTES = ARGV[0]? || "../ruby_llm-source/spec/fixtures/vcr_cassettes"
OUT       = ARGV[1]? || "spec/fixtures/cassettes"
PER_KIND  = 4 # cap fixtures per (provider, kind) to keep the library lean

def provider_for(uri : String) : String
  case uri
  when .includes?("api.openai.com")            then "openai"
  when .includes?("api.anthropic.com")         then "anthropic"
  when .includes?("generativelanguage.google") then "gemini"
  when .includes?("aiplatform.google")         then "vertexai"
  when .includes?("bedrock")                   then "bedrock"
  when .includes?("api.mistral.ai")            then "mistral"
  when .includes?("api.deepseek.com")          then "deepseek"
  when .includes?("openrouter.ai")             then "openrouter"
  when .includes?("api.perplexity.ai")         then "perplexity"
  when .includes?("api.x.ai")                  then "xai"
  when .includes?("azure.com")                 then "azure"
  when .includes?("11434"), .includes?("ollama") then "ollama"
  else                                              "other"
  end
end

def kind_for(uri : String, body : String) : String
  streaming = body.lstrip.starts_with?("data:") || body.includes?("\ndata:")
  base =
    case uri
    when .includes?("chat/completions"), .includes?(":generateContent"), .includes?(":streamGenerateContent"), .includes?("/messages"), .includes?("/converse") then "chat"
    when .includes?("embeddings"), .includes?(":embedContent"), .includes?(":batchEmbed")                                                                       then "embedding"
    when .includes?("images")                                                                                                                                    then "image"
    when .includes?("moderations")                                                                                                                               then "moderation"
    when .includes?("transcriptions"), .includes?("audio")                                                                                                       then "transcription"
    when .includes?("/models")                                                                                                                                   then "models"
    else                                                                                                                                                            "chat"
    end
  streaming && base == "chat" ? "stream" : base
end

counts = Hash(String, Int32).new(0)
harvested = 0
parse_failures = 0

Dir.glob(File.join(CASSETTES, "*.yml")).each do |path|
  yaml = begin
    YAML.parse(File.read(path))
  rescue
    parse_failures += 1
    next
  end

  interactions = yaml["http_interactions"]?
  next unless interactions

  interactions.as_a.each do |interaction|
    req = interaction["request"]?
    res = interaction["response"]?
    next unless req && res

    uri = req["uri"]?.try(&.as_s) || ""
    status = res.dig?("status", "code").try(&.as_i?) || 200
    body = res.dig?("body", "string").try(&.as_s) || ""
    next if body.empty? || status >= 400

    provider = provider_for(uri)
    next if provider == "other"
    kind = kind_for(uri, body)
    key = "#{provider}/#{kind}"

    n = counts[key]
    next if n >= PER_KIND
    counts[key] = n + 1

    dir = File.join(OUT, provider)
    FileUtils.mkdir_p(dir)
    ext = kind == "stream" ? "sse" : "json"
    File.write(File.join(dir, "#{kind}_#{n + 1}.#{ext}"), body)
    harvested += 1
  end
end

puts "Harvested #{harvested} fixtures (#{parse_failures} cassettes unparseable) into #{OUT}"
counts.to_a.sort_by(&.[0]).each { |k, v| puts "  #{k.ljust(22)} #{v}" }
