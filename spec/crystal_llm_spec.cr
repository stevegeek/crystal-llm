require "./spec_helper"

describe CrystalLLM do
  it "exposes a VERSION" do
    CrystalLLM::VERSION.should match(/\A\d+\.\d+\.\d+/)
  end
end
