# ported from lib/ruby_llm/deprecator.rb @ ruby_llm 1.16.0
module CrystalLLM
  # Owns CrystalLLM deprecation warnings so applications and tests can decide how
  # aggressively to handle compatibility paths.
  #
  # DIVERGENCE: ruby_llm dispatches on `config.deprecation_behavior` symbols
  # (:silence/:raise/else). The foundation keeps `deprecation_behavior` a `String`
  # ("silence"/"raise"/anything-else → warn) — symbols-as-runtime-data become
  # String in this port (design R5). Dispatch is on those string values, so an
  # unrecognized value falls through to the logger, matching Ruby's `else`.
  class Deprecator
    def warn(message : String) : Nil
      case CrystalLLM.config.deprecation_behavior
      when "silence"
        nil
      when "raise"
        raise DeprecationError.new(message)
      else
        # `::Log#warn` takes a block in Crystal (lazy message), unlike Ruby's
        # `logger.warn(message)`.
        CrystalLLM.logger.warn { message }
      end
    end

    def deprecate(name : String, replacement : String, removal : String) : Nil
      warn("#{name} is deprecated and will be removed in CrystalLLM #{removal}. Use #{replacement} instead.")
    end
  end

  # Raised by `Deprecator#warn` when `config.deprecation_behavior` is "raise".
  # Descends from `Exception` directly (the foundation's convention for ruby_llm's
  # `StandardError` siblings; see error.cr).
  class DeprecationError < Exception; end
end
