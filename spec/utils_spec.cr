require "./spec_helper"
require "../src/crystal_llm/utils"

# REGRESSION (BUG 5): Utils.deep_merge used a SHALLOW `original.dup`, so the result
# aliased `original`'s untouched nested hash objects. Mutating the result (or a
# nested override hash carried over) could then silently corrupt the inputs. The fix
# deep-dups carried-over nodes so the output shares NO mutable hash with either input.
private def jnum(n : Int64) : JSON::Any
  JSON::Any.new(n)
end

private def jstr(s : String) : JSON::Any
  JSON::Any.new(s)
end

private def jobj(h : Hash(String, JSON::Any)) : JSON::Any
  JSON::Any.new(h)
end

describe CrystalLLM::Utils do
  describe ".deep_merge" do
    it "merges nested hashes, with override scalars winning and siblings preserved" do
      original = {"a" => jobj({"x" => jnum(1), "keep" => jnum(7)}), "top" => jnum(0)}
      override = {"a" => jobj({"x" => jnum(99)})}

      result = CrystalLLM::Utils.deep_merge(original, override)

      result["a"]["x"].as_i.should eq(99)   # override wins
      result["a"]["keep"].as_i.should eq(7) # sibling preserved
      result["top"].as_i.should eq(0)       # untouched top-level key preserved
    end

    it "lets an override scalar win where the original holds a hash" do
      original = {"a" => jobj({"x" => jnum(1)})}
      override = {"a" => jstr("scalar")}

      result = CrystalLLM::Utils.deep_merge(original, override)

      result["a"].as_s?.should eq("scalar")
    end

    it "does not mutate either input (including their nested hashes)" do
      original = {"a" => jobj({"x" => jnum(1), "keep" => jnum(7)})}
      override = {"a" => jobj({"x" => jnum(99), "added" => jnum(2)})}
      original_snapshot = original.to_json
      override_snapshot = override.to_json

      CrystalLLM::Utils.deep_merge(original, override)

      original.to_json.should eq(original_snapshot)
      override.to_json.should eq(override_snapshot)
    end

    it "returns a hash that shares no mutable nested object with the inputs" do
      # An untouched nested branch in the original (the shallow-dup hazard): the
      # result must NOT alias original's nested hash, so mutating the result leaves
      # the input intact.
      original = {"b" => jobj({"deep" => jnum(1)}), "c" => jnum(5)}
      override = {"c" => jnum(9)}

      result = CrystalLLM::Utils.deep_merge(original, override)
      result["b"].as_h.same?(original["b"].as_h).should be_false

      result["b"].as_h["deep"] = jnum(999)
      original["b"]["deep"].as_i.should eq(1) # original untouched
    end

    it "deep-dups override-supplied nested hashes carried into the result" do
      original = {} of String => JSON::Any
      override = {"new" => jobj({"k" => jnum(1)})}

      result = CrystalLLM::Utils.deep_merge(original, override)
      result["new"].as_h.same?(override["new"].as_h).should be_false

      result["new"].as_h["k"] = jnum(42)
      override["new"]["k"].as_i.should eq(1) # override input untouched
    end
  end

  describe ".parse_iso_date_prefix" do
    it "parses full ISO dates" do
      CrystalLLM::Utils.parse_iso_date_prefix("2026-06-08").should eq(Time.utc(2026, 6, 8))
    end

    it "expands year-month to the first of the month" do
      CrystalLLM::Utils.parse_iso_date_prefix("2026-06").should eq(Time.utc(2026, 6, 1))
    end

    it "expands bare years to Jan 1" do
      CrystalLLM::Utils.parse_iso_date_prefix("2026").should eq(Time.utc(2026, 1, 1))
    end

    it "returns nil for blank and malformed input" do
      CrystalLLM::Utils.parse_iso_date_prefix("").should be_nil
      CrystalLLM::Utils.parse_iso_date_prefix("junk").should be_nil
      CrystalLLM::Utils.parse_iso_date_prefix("2026-13-40").should be_nil
    end
  end

  describe ".iso_date_prefix_to_utc_midnight_string" do
    it "renders UTC midnight strings" do
      CrystalLLM::Utils.iso_date_prefix_to_utc_midnight_string("2026-06").should eq("2026-06-01 00:00:00 UTC")
    end

    it "returns nil when the date does not parse" do
      CrystalLLM::Utils.iso_date_prefix_to_utc_midnight_string("junk").should be_nil
    end
  end
end
