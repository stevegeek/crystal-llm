require "./spec_helper"
require "../src/crystal_llm/deprecator"

# A minimal in-memory Log backend so we can assert whether `#warn` emitted a
# record (the Crystal stand-in for ruby_llm's `have_received(:warn)` mock).
class DeprecatorSpecCapturingBackend < ::Log::Backend
  getter entries = [] of ::Log::Entry

  def initialize
    super(:direct)
  end

  def write(entry : ::Log::Entry) : Nil
    @entries << entry
  end
end

private def with_deprecation_behavior(behavior : String, &)
  original = CrystalLLM.config.deprecation_behavior
  CrystalLLM.config.deprecation_behavior = behavior
  begin
    yield
  ensure
    CrystalLLM.config.deprecation_behavior = original
  end
end

# Captures log output through a temporary backend. The spec runner sets the
# default Log level to `None`, so we raise it to `Debug` for the assertion and
# restore both backend and level afterwards.
private def with_captured_log(&)
  backend = DeprecatorSpecCapturingBackend.new
  original_level = CrystalLLM.logger.level
  CrystalLLM.logger.level = ::Log::Severity::Debug
  CrystalLLM.logger.backend = backend
  begin
    yield backend
  ensure
    CrystalLLM.logger.backend = nil
    CrystalLLM.logger.level = original_level
  end
end

describe CrystalLLM::Deprecator do
  describe "#warn" do
    it "can raise deprecations for strict test suites" do
      with_deprecation_behavior("raise") do
        expect_raises(CrystalLLM::DeprecationError, "old API") do
          CrystalLLM::Deprecator.new.warn("old API")
        end
      end
    end

    it "can silence deprecations" do
      with_captured_log do |backend|
        with_deprecation_behavior("silence") do
          CrystalLLM::Deprecator.new.warn("old API")
        end

        backend.entries.should be_empty
      end
    end

    it "logs a warning for any other behavior" do
      with_captured_log do |backend|
        with_deprecation_behavior("warn") do
          CrystalLLM::Deprecator.new.warn("old API")
        end

        backend.entries.size.should eq(1)
        backend.entries.first.severity.should eq(::Log::Severity::Warn)
        backend.entries.first.message.should eq("old API")
      end
    end
  end

  describe "#deprecate" do
    it "builds a removal/replacement message and routes it through #warn" do
      with_deprecation_behavior("raise") do
        expect_raises(
          CrystalLLM::DeprecationError,
          "Chat#old is deprecated and will be removed in CrystalLLM 2.0. Use Chat#new instead."
        ) do
          CrystalLLM::Deprecator.new.deprecate("Chat#old", replacement: "Chat#new", removal: "2.0")
        end
      end
    end
  end
end
