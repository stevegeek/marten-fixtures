require "./spec_helper"

describe MartenFixtures::Label do
  describe ".identify/1" do
    it "produces a deterministic Int64 within the Rails MAX_ID window" do
      id = MartenFixtures::Label.identify("david")
      id.should be_a(Int64)
      id.should eq(Digest::CRC32.checksum("david").to_i64 % MartenFixtures::Label::MAX_ID)
      id.should be < MartenFixtures::Label::MAX_ID
      id.should eq(MartenFixtures::Label.identify("david"))
    end

    it "yields distinct ids for typical fixture labels" do
      labels = %w[david alice engineering marketing welcome kickoff important lead_welcome lead_kickoff lead_important]
      ids = labels.map { |l| MartenFixtures::Label.identify(l) }
      ids.uniq.size.should eq(labels.size)
    end
  end

  describe ".identify/2 with a UUID primary-key field" do
    it "returns a deterministic UUID string for Field::UUID" do
      uuid_field = Marten::DB::Field::UUID.new("id", primary_key: true)
      value = MartenFixtures::Label.identify("david", uuid_field)
      value.should be_a(String)
      value.should eq(::UUID.v5("david", MartenFixtures::Label::OID_NAMESPACE).to_s)
      value.should eq(MartenFixtures::Label.identify("david", uuid_field))
    end

    it "matches Rails 7.x ActiveRecord::FixtureSet OID-namespace UUID for the same label (L9)" do
      # Rails generates fixture UUIDs via
      # `Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE, label)`.
      # The OID namespace is `6ba7b812-9dad-11d1-80b4-00c04fd430c8`.
      # We hardcode the exact UUID v5 hex literal that Rails (and any
      # other RFC-4122-compliant generator) produces for `"david"` under
      # the OID namespace, so a regression to the DNS namespace (Phase 3
      # baseline) — or any other mis-namespacing — flips this spec
      # immediately. Computed via Crystal's `UUID.v5("david", OID)`;
      # equivalent Ruby:
      #   require "digest/uuid"
      #   Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE, "david")
      #   # => "386b3b50-02a0-5db7-9b60-5d4749898c56"
      uuid_field = Marten::DB::Field::UUID.new("id", primary_key: true)
      MartenFixtures::Label.identify("david", uuid_field).should eq("386b3b50-02a0-5db7-9b60-5d4749898c56")
    end

    it "falls back to the CRC32 Int64 when the pk field is not a UUID" do
      pk_field = Marten::DB::Field::BigInt.new("id", primary_key: true)
      MartenFixtures::Label.identify("engineering", pk_field).should eq(
        MartenFixtures::Label.identify("engineering")
      )
    end
  end
end

describe "MartenFixtures.identify" do
  it "delegates to Label.identify and returns the same Int64" do
    MartenFixtures.identify("david").should eq(MartenFixtures::Label.identify("david"))
  end
end
