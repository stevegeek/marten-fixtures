require "./spec_helper"

# Phase 4 regression specs covering the post-review MFR1–MFR7 items
# (see SHARD_REVIEWS_TRACKING.md, marten-fixtures section).
#
# MFR3 is ACK-only (clarifying comment lives in `phase2_fixes_spec.cr`
# under the M4 describe); MFR6 is verified by every other spec that
# asserts `MartenFixtures.last_label_registry.nil?` working from a
# clean baseline, but we also pin it explicitly here for documentation.

# Spy that records every issue_session_replication_role call. Combined
# with PostgresFakingInserter's `adapter_kind :postgres` override, this
# lets us assert SET issuance under the SQLite spec backend without a
# real Postgres connection. The bulk_insert + bump_sequences calls do
# go to the real SQLite connection — bump_sequences is only reached
# under the `disable_constraints=true` AND `postgres?` branch, so we
# stub `postgres?` away too where needed.
private class SetReplicationRoleSpy < MartenFixtures::Inserter
  getter session_role_calls : Array(String) = [] of String

  protected def adapter_kind : Symbol
    :postgres
  end

  protected def issue_session_replication_role(value : String) : Nil
    @session_role_calls << value
    # No-op: do NOT issue the SET on the real (SQLite) connection.
  end

  # Suppress the Postgres-only bump_sequences path (which would call
  # pg_get_serial_sequence on the real SQLite connection and fail).
  protected def bump_sequences_for(models : Array(Marten::DB::Model.class)) : Nil
    # no-op: avoid hitting pg_get_serial_sequence on the real SQLite conn.
  end
end

# MFR1 / MFR4: spy that records every bulk_insert call's (model, rows)
# tuple in invocation order. Combined with the loader's `build_inserter`
# hook, lets us verify within-file topo-sort produced parent-before-child
# row order without relying on FK enforcement.
private class BulkInsertSpy < MartenFixtures::Inserter
  alias Call = NamedTuple(model: Marten::DB::Model.class, rows: Array(Hash(String, ::DB::Any)))
  getter calls : Array(Call) = [] of Call

  protected def bulk_insert_slice(
    model : Marten::DB::Model.class,
    slice : Array(Hash(String, ::DB::Any)),
  ) : Nil
    @calls << {model: model, rows: slice.dup}
    super
  end
end

# Loader subclass that swaps in a BulkInsertSpy so we can capture the
# row-order handed to the real Marten bulk_insert.
private class SpyLoader < MartenFixtures::Loader
  getter spy : BulkInsertSpy? = nil

  protected def build_inserter(connection : Marten::DB::Connection::Base) : MartenFixtures::Inserter
    inserter = BulkInsertSpy.new(connection)
    @spy = inserter
    inserter
  end
end

describe "Phase 4 — MFR1 disable_constraints SET issuance locked under SQLite" do
  it "issues SET session_replication_role = 'replica' when disable_constraints? is true" do
    MartenFixtures.configure(&.disable_constraints = true)

    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [
      {
        "id"         => 1_i64.as(::DB::Any),
        "name"       => "MFR1-on".as(::DB::Any),
        "created_at" => Time.utc.as(::DB::Any),
        "updated_at" => Time.utc.as(::DB::Any),
      },
    ]

    spy = SetReplicationRoleSpy.new(Marten::DB::Connection.default)
    spy.insert_all(rows_by_model)

    # Expect exactly one 'replica' (disable) call and one 'origin'
    # (restore) call, in that order. Pre-MFR1 the spec used
    # `expect_raises(Exception)` which would pass even if NO SET was
    # ever issued (e.g. if the disable_constraints check silently
    # swallowed the flag).
    spy.session_role_calls.should eq(["replica", "origin"])
  end

  it "does NOT issue SET session_replication_role when disable_constraints? is false" do
    MartenFixtures.configure(&.disable_constraints = false)

    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [
      {
        "id"         => 2_i64.as(::DB::Any),
        "name"       => "MFR1-off".as(::DB::Any),
        "created_at" => Time.utc.as(::DB::Any),
        "updated_at" => Time.utc.as(::DB::Any),
      },
    ]

    spy = SetReplicationRoleSpy.new(Marten::DB::Connection.default)
    spy.insert_all(rows_by_model)

    spy.session_role_calls.should be_empty
  end
end

describe "Phase 4 — MFR2 Inserter reads @config.disable_constraints? not the global" do
  it "honours a per-loader Configuration with disable_constraints=false while the global is true" do
    # Global says "issue the SET" (the spec_helper default).
    MartenFixtures.configure(&.disable_constraints = true)
    MartenFixtures.configuration.disable_constraints?.should be_true

    # Local config says "skip the SET".
    local_config = MartenFixtures::Configuration.new
    local_config.disable_constraints = false
    local_config.disable_constraints?.should be_false

    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [
      {
        "id"         => 11_i64.as(::DB::Any),
        "name"       => "MFR2-local".as(::DB::Any),
        "created_at" => Time.utc.as(::DB::Any),
        "updated_at" => Time.utc.as(::DB::Any),
      },
    ]

    spy = SetReplicationRoleSpy.new(Marten::DB::Connection.default, local_config)
    spy.insert_all(rows_by_model)

    # Local wins: no SET issued, even though the global said yes.
    # Pre-MFR2 this would record ["replica", "origin"] because the
    # inserter consulted `MartenFixtures.configuration` instead of
    # `@config`.
    spy.session_role_calls.should be_empty
  end

  it "honours a per-loader Configuration with disable_constraints=true while the global is false" do
    # Symmetric: local says "issue", global says "skip" — local wins.
    MartenFixtures.configure(&.disable_constraints = false)
    MartenFixtures.configuration.disable_constraints?.should be_false

    local_config = MartenFixtures::Configuration.new
    local_config.disable_constraints = true
    local_config.disable_constraints?.should be_true

    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [
      {
        "id"         => 12_i64.as(::DB::Any),
        "name"       => "MFR2-local-on".as(::DB::Any),
        "created_at" => Time.utc.as(::DB::Any),
        "updated_at" => Time.utc.as(::DB::Any),
      },
    ]

    spy = SetReplicationRoleSpy.new(Marten::DB::Connection.default, local_config)
    spy.insert_all(rows_by_model)

    spy.session_role_calls.should eq(["replica", "origin"])
  end
end

describe "Phase 4 — MFR4 within-file self-FK row order is topo-sorted (spy-locked)" do
  it "delivers rows to bulk_insert in parent-before-child order even when YAML is scrambled" do
    # Pre-L4 a scrambled YAML (leaf -> middle -> root) handed rows to
    # bulk_insert in YAML order; on Postgres that's an FK violation,
    # on SQLite it silently orphans. L4 added the within-file topo
    # sort, but the existing spec relied on the resulting DB state
    # being correct — which is invisible on SQLite (no FK enforcement)
    # if the sort were ever bypassed. The spy makes the contract
    # explicit by inspecting the row order passed to bulk_insert.
    loader = SpyLoader.new([Path["spec/fixtures_l4_scrambled/categories.yml"]])
    loader.load

    spy = loader.spy.not_nil!
    category_calls = spy.calls.select { |c| c[:model] == Category }
    category_calls.size.should eq(1)
    inserted_rows = category_calls.first[:rows]

    # The fixture has three rows: root (no parent), middle (parent=root),
    # leaf (parent=middle). Post-MFR4 they must arrive at bulk_insert
    # in dependency order — root first, then middle, then leaf — even
    # though the YAML file lists them in reverse.
    root_id = MartenFixtures::Label.identify("root")
    middle_id = MartenFixtures::Label.identify("middle")
    leaf_id = MartenFixtures::Label.identify("leaf")

    inserted_pks = inserted_rows.map { |r| r["id"] }
    inserted_pks.should eq([root_id.as(::DB::Any), middle_id.as(::DB::Any), leaf_id.as(::DB::Any)])

    # Cross-check: every non-root row's parent_id must reference a
    # row that already appears earlier in the insert order. (This is
    # the actual FK-correctness invariant the spy is proving.)
    seen_ids = Set(::DB::Any).new
    inserted_rows.each do |row|
      if (parent_id = row["parent_id"]?) && !parent_id.nil?
        seen_ids.includes?(parent_id).should be_true
      end
      seen_ids << row["id"]
    end
  end

  it "preserves YAML order for the ordered fixture (the sort is a no-op when already sorted)" do
    loader = SpyLoader.new([Path["spec/fixtures_l4_ordered/categories.yml"]])
    loader.load

    spy = loader.spy.not_nil!
    category_calls = spy.calls.select { |c| c[:model] == Category }
    inserted_pks = category_calls.first[:rows].map { |r| r["id"] }
    inserted_pks.should eq([
      MartenFixtures::Label.identify("root").as(::DB::Any),
      MartenFixtures::Label.identify("middle").as(::DB::Any),
      MartenFixtures::Label.identify("leaf").as(::DB::Any),
    ])
  end
end

describe "Phase 4 — MFR5 String-PK explicit ids preserved verbatim" do
  it "stores `code: \"abc-42\"` as a String, not an Int64-coerced value" do
    # Coupon has a `:string` primary key. A YAML fixture supplying
    # `code: "abc-42"` should round-trip as the String "abc-42".
    # Pre-MFR5 this still worked (because "abc-42".to_i64? is nil),
    # so the *real* regression target is the integer-looking-string
    # case below — but we also pin the non-integer case to document
    # the contract.
    tmp_root = Path[Dir.tempdir] / "marten_fixtures_mfr5_a_#{Random::Secure.hex}"
    Dir.mkdir_p(tmp_root.to_s)
    File.write(
      (tmp_root / "coupons.yml").to_s,
      "summer:\n  code: \"abc-42\"\n  name: Summer\n",
    )

    MartenFixtures::Loader.new([tmp_root / "coupons.yml"]).load

    Coupon.all.size.should eq(1)
    Coupon.get!(pk: "abc-42").name.should eq("Summer")
  ensure
    FileUtils.rm_rf(tmp_root.to_s) if tmp_root
  end

  it "stores `code: \"99\"` as the String \"99\" on a String PK (NOT Int64 99)" do
    # MFR5 regression target: pre-fix, the loader's `to_i64?` coercion
    # would convert "99" → 99_i64 and the label registry would record
    # the row's pk as the Int64. At insert time the row's `code:` column
    # was a String "99" (because Marten serialises whatever the user
    # passed), but the label registry was an Int64 99 — so cross-fixture
    # FK references via the label would resolve to the wrong type.
    # Post-MFR5 the value stays String through both paths.
    tmp_root = Path[Dir.tempdir] / "marten_fixtures_mfr5_b_#{Random::Secure.hex}"
    Dir.mkdir_p(tmp_root.to_s)
    File.write(
      (tmp_root / "coupons.yml").to_s,
      "fall:\n  code: \"99\"\n  name: Fall\n",
    )

    MartenFixtures::Loader.new([tmp_root / "coupons.yml"]).load

    Coupon.get!(pk: "99").name.should eq("Fall")

    # And: the LabelRegistry's lookup returns the String, not an Int64.
    registry = MartenFixtures.last_label_registry.not_nil!
    looked_up = registry.lookup(Coupon, "fall")
    looked_up.should eq("99")
    looked_up.should be_a(String)
  ensure
    FileUtils.rm_rf(tmp_root.to_s) if tmp_root
  end

  it "still coerces `id: \"42\"` to Int64 for integer-PK models (existing behaviour preserved)" do
    # MFR5 only changes the String-PK branch. Integer-PK models still
    # accept over-quoted YAML integer-looking strings (the common case
    # where `id: 42` and `id: "42"` are interchangeable in YAML).
    tmp_root = Path[Dir.tempdir] / "marten_fixtures_mfr5_c_#{Random::Secure.hex}"
    Dir.mkdir_p(tmp_root.to_s)
    File.write(
      (tmp_root / "accounts.yml").to_s,
      "first:\n  id: \"42\"\n  name: Quoted\n",
    )

    MartenFixtures::Loader.new([tmp_root / "accounts.yml"]).load

    Account.get!(pk: 42_i64).name.should eq("Quoted")
    registry = MartenFixtures.last_label_registry.not_nil!
    registry.lookup(Account, "first").should eq(42_i64)
  ensure
    FileUtils.rm_rf(tmp_root.to_s) if tmp_root
  end
end

describe "Phase 4 — MFR6 last_label_registry reset between examples" do
  it "starts each example with last_label_registry nil (cross-test isolation)" do
    # The spec_helper before_each now resets the module-global so a
    # prior `load` cannot poison the next example's baseline. We assert
    # the entry state here; the next spec proves the reset really fires
    # by depending on this being a clean baseline.
    MartenFixtures.last_label_registry.should be_nil
  end

  it "still publishes the registry after a load (the reset does not break the publish path)" do
    MartenFixtures::Loader.new([Path["spec/fixtures/accounts.yml"]]).load
    MartenFixtures.last_label_registry.should_not be_nil
  end
end

describe "Phase 4 — MFR7 restore catches only ::DB::Error (not Exception)" do
  it "lets a non-DB error propagate out of the restore path" do
    # We synthesise the path by overriding `issue_session_replication_role`
    # on a subclass: on the 'origin' restore call we raise a non-DB
    # programming error. Pre-MFR7 (`rescue nil`) would swallow it; the
    # ensure block would silently complete and the user would never see
    # the bug. Post-MFR7 (`rescue ::DB::Error`) the KeyError propagates.

    raised = false
    begin
      RaisingRestoreInserter.new(Marten::DB::Connection.default).insert_all(
        Hash(Marten::DB::Model.class, Array(Hash(String, ::DB::Any))).new,
      )
    rescue KeyError
      raised = true
    end
    raised.should be_true
  end

  it "still swallows ::DB::Error from the restore (best-effort semantics preserved)" do
    raised = false
    begin
      DbRaisingRestoreInserter.new(Marten::DB::Connection.default).insert_all(
        Hash(Marten::DB::Model.class, Array(Hash(String, ::DB::Any))).new,
      )
    rescue ::DB::Error
      raised = true
    end
    raised.should be_false
  end
end

# Spy that raises a programming error on the 'origin' restore call.
# Verifies that MFR7's narrowed `rescue ::DB::Error` lets the
# non-DB exception propagate.
private class RaisingRestoreInserter < MartenFixtures::Inserter
  protected def adapter_kind : Symbol
    :postgres
  end

  protected def issue_session_replication_role(value : String) : Nil
    raise KeyError.new("simulated programming error from restore") if value == "origin"
    # 'replica' SET is a no-op (don't actually hit the real SQLite conn).
  end

  protected def bump_sequences_for(models : Array(Marten::DB::Model.class)) : Nil
    # no-op: avoid hitting pg_get_serial_sequence on the real SQLite conn.
  end
end

# Spy that raises a ::DB::Error on the 'origin' restore call. The
# narrowed rescue in MFR7 should still swallow this.
private class DbRaisingRestoreInserter < MartenFixtures::Inserter
  protected def adapter_kind : Symbol
    :postgres
  end

  protected def issue_session_replication_role(value : String) : Nil
    raise ::DB::Error.new("simulated db error from restore") if value == "origin"
  end

  protected def bump_sequences_for(models : Array(Marten::DB::Model.class)) : Nil
    # no-op: avoid hitting pg_get_serial_sequence on the real SQLite conn.
  end
end
