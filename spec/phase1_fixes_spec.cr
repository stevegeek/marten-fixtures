require "./spec_helper"

private class Phase1AccessorHost
  include MartenFixtures::Accessors
end

# Phase 1 regression specs covering the three silent-corruption findings
# in `reviews/marten-fixtures-review.md` (H1 / H2 / H3).
describe "Phase 1 — explicit-id label registry sync (H1)" do
  it "uses an explicit YAML `id:` for cross-fixture FK resolution" do
    MartenFixtures::Loader.new([
      Path["spec/fixtures_h1/accounts.yml"],
      Path["spec/fixtures_h1/users.yml"],
      Path["spec/fixtures_h1/posts.yml"],
    ]).load

    # Pre-condition: the row was inserted with the explicit PK.
    User.get!(pk: 999_i64).name.should eq("David")
    Account.get!(pk: 4242_i64).name.should eq("EngineeringExplicit")

    # H1 regression: the cross-fixture label `david_explicit` (used by
    # `welcome_explicit.author`) must resolve to the explicit PK (999),
    # not the CRC32 derivation. Pre-fix this would have failed with
    # either an orphan row (SQLite, no FK enforcement) or a FK violation
    # (Postgres).
    post = Post.all.find!(&.title.==("WelcomeExplicit"))
    post.author_id.should eq(999_i64)
    post.author!.name.should eq("David")

    # FK target chain end-to-end: User.account_id should match the
    # explicit Account PK.
    User.get!(pk: 999_i64).account_id.should eq(4242_i64)
  end

  it "exposes the populated registry via MartenFixtures.last_label_registry" do
    MartenFixtures::Loader.new([
      Path["spec/fixtures_h1/accounts.yml"],
      Path["spec/fixtures_h1/users.yml"],
    ]).load

    registry = MartenFixtures.last_label_registry.not_nil!
    registry.lookup(User, "david_explicit").should eq(999_i64)
    registry.lookup(Account, "engineering_explicit").should eq(4242_i64)
  end

  it "lets Accessors#fixture find explicit-id rows by label (L12)" do
    MartenFixtures::Loader.new([
      Path["spec/fixtures_h1/accounts.yml"],
      Path["spec/fixtures_h1/users.yml"],
    ]).load

    host = Phase1AccessorHost.new
    david = host.fixture(User, :david_explicit).as(User)
    david.pk.should eq(999_i64)
    david.name.should eq("David")
  end

  it "still derives the CRC32 PK for rows without explicit `id:`" do
    MartenFixtures::Loader.new([
      Path["spec/fixtures/accounts.yml"],
      Path["spec/fixtures/users.yml"],
    ]).load

    expected_david = MartenFixtures::Label.identify("david")
    User.get!(pk: expected_david).name.should eq("David")

    registry = MartenFixtures.last_label_registry.not_nil!
    registry.lookup(User, "david").should eq(expected_david)
  end
end

describe "Phase 1 — heterogeneous row shapes within one fixture file (H2)" do
  it "loads a file where rows disagree on which optional columns are set" do
    MartenFixtures::Loader.new([Path["spec/fixtures_h2/widgets.yml"]]).load

    Widget.all.size.should eq(2)
    complete = Widget.get!(pk: MartenFixtures::Label.identify("complete"))
    minimal = Widget.get!(pk: MartenFixtures::Label.identify("minimal"))

    complete.name.should eq("Complete")
    complete.note.should eq("This one has a note.")

    minimal.name.should eq("Minimal")
    minimal.note.should be_nil
  end
end

describe "Phase 1 — JSON / Duration / Date YAML coercion (H3)" do
  before_each { MartenFixtures::Loader.new([Path["spec/fixtures_h3/samples.yml"]]).load }

  it "loads a nested JSON column from a YAML mapping" do
    sample = Sample.get!(pk: MartenFixtures::Label.identify("nested_json"))
    json = sample.metadata.not_nil!
    json["nested"]["key"].as_s.should eq("value")
    json["nested"]["count"].as_i.should eq(3)
    json["nested"]["truthy"].as_bool.should be_true
    json["nested"]["missing"].raw.should be_nil
    json["list"][0].as_i.should eq(1)
    json["list"][1].as_s.should eq("two")
    json["list"][2].as_f.should eq(3.14)
    json["bare_string"].as_s.should eq("hi")
  end

  it "loads JSON arrays, scalars, and null as the column value" do
    Sample.get!(pk: MartenFixtures::Label.identify("scalar_json_array"))
      .metadata.not_nil!.as_a.map(&.as_s).should eq(["one", "two", "three"])
    Sample.get!(pk: MartenFixtures::Label.identify("scalar_json_string"))
      .metadata.not_nil!.as_s.should eq("just a string")
    Sample.get!(pk: MartenFixtures::Label.identify("scalar_json_number"))
      .metadata.not_nil!.as_i.should eq(42)
    Sample.get!(pk: MartenFixtures::Label.identify("scalar_json_bool"))
      .metadata.not_nil!.as_bool.should be_true
    Sample.get!(pk: MartenFixtures::Label.identify("scalar_json_null"))
      .metadata.should be_nil
  end

  it "loads Duration columns from a numeric (seconds) YAML literal" do
    sample = Sample.get!(pk: MartenFixtures::Label.identify("duration_numeric"))
    sample.ttl.should eq(90.seconds)
  end

  it "loads Duration columns from an ISO-8601 string" do
    sample = Sample.get!(pk: MartenFixtures::Label.identify("duration_iso"))
    sample.ttl.should eq(1.hour + 30.minutes + 15.seconds)
  end

  it "loads Duration columns from a shorthand string" do
    sample = Sample.get!(pk: MartenFixtures::Label.identify("duration_shorthand"))
    sample.ttl.should eq(1.hour + 30.minutes)
  end

  it "loads Duration columns from a fractional-seconds numeric literal" do
    sample = Sample.get!(pk: MartenFixtures::Label.identify("duration_fractional"))
    sample.ttl.should eq(1.5.seconds)
  end

  it "loads Date columns from a YAML date literal" do
    sample = Sample.get!(pk: MartenFixtures::Label.identify("date_yaml_literal"))
    sample.scheduled_on.not_nil!.year.should eq(2026)
    sample.scheduled_on.not_nil!.month.should eq(5)
    sample.scheduled_on.not_nil!.day.should eq(20)
  end

  it "loads Date columns from an explicit ISO-8601 string" do
    sample = Sample.get!(pk: MartenFixtures::Label.identify("date_string"))
    sample.scheduled_on.not_nil!.year.should eq(2026)
    sample.scheduled_on.not_nil!.month.should eq(6)
    sample.scheduled_on.not_nil!.day.should eq(15)
  end
end
