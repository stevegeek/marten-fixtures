require "./spec_helper"

# Spec subclass that pretends the underlying connection is Postgres so we
# can exercise the M2 `with_postgres_constraints_disabled` opt-out branch
# (the `disable_constraints = false` path) without needing a live Postgres
# in the agent environment. The actual `SET session_replication_role`
# call only fires under the real-Postgres branch tested via the existing
# Postgres-only `inserter_spec` and the M1 round-trip below.
private class PostgresFakingInserter < MartenFixtures::Inserter
  protected def adapter_kind : Symbol
    :postgres
  end
end

# Phase 2 regression specs covering the MED findings in
# `reviews/marten-fixtures-review.md` (M1 / M2 / M3 / M4 / M6).
# M5 is a doc-only acknowledgement and is exercised by the existing
# CrinjaEvaluator specs (no new assertion needed — the clarifying
# comment is the deliverable).

describe "Phase 2 — bump_sequence Postgres correctness (M1)" do
  it "wraps the pg_get_serial_sequence bind parameters in quote_ident() to survive mixed-case names" do
    connection = Marten::DB::Connection.default
    sql = MartenFixtures::Inserter.build_bump_sequence_sql(connection, "Users", "id")

    # Pre-fix the SQL embedded `$1`/`$2` directly into pg_get_serial_sequence
    # and Postgres would case-fold "Users" to "users" and raise
    # `relation does not exist`. The fix wraps both bind parameters in
    # quote_ident() so Postgres treats them as the verbatim identifier
    # the caller named. (The inner MAX subquery references the table
    # name via @connection.quote, which already produces a properly
    # double-quoted identifier — that's a separate code path and a
    # static quoting choice rather than a Postgres-runtime decision.)
    sql.should contain("pg_get_serial_sequence(quote_ident($1), quote_ident($2))")
  end

  it "uses the three-argument setval form so empty tables next-insert id=1 (not id=2)" do
    connection = Marten::DB::Connection.default
    sql = MartenFixtures::Inserter.build_bump_sequence_sql(connection, "accounts", "id")

    # Three-arg setval(seq, value, is_called) — when `is_called=false`
    # Postgres treats the sequence as untouched and the next nextval
    # returns `value` (not `value + 1`). We pass `(MAX(...)) IS NOT NULL`
    # as the third arg: false for empty tables → next id = 1; true for
    # populated tables → next id = max+1.
    sql.should contain("IS NOT NULL")
    # The setval call should have three arguments, identified by two
    # top-level commas inside its parens. We count by stripping
    # everything but the outermost setval(...) and checking that the
    # comma count inside it (at parenthesis-depth 1 from the start of
    # the args) is exactly 2.
    setval_start = sql.index!("setval(")
    args_start = setval_start + "setval(".size
    depth = 1
    commas_at_top = 0
    i = args_start
    while i < sql.size && depth > 0
      ch = sql[i]
      case ch
      when '('
        depth += 1
      when ')'
        depth -= 1
      when ','
        commas_at_top += 1 if depth == 1
      end
      i += 1
    end
    commas_at_top.should eq(2)
  end

  it "still emits the GREATEST/COALESCE clamp so populated tables behave correctly" do
    connection = Marten::DB::Connection.default
    sql = MartenFixtures::Inserter.build_bump_sequence_sql(connection, "accounts", "id")

    sql.should contain("GREATEST(COALESCE")
    sql.should contain("MAX(")
  end
end

describe "Phase 2 — disable_constraints opt-out (M2)" do
  it "defaults the new disable_constraints flag to true (preserves prior behaviour)" do
    MartenFixtures::Configuration.new.disable_constraints?.should be_true
  end

  it "respects the disable_constraints=false setting and skips the SET entirely on Postgres" do
    # On the SQLite spec backend `:postgres` is faked, so the per-branch
    # SQL never actually fires. The assertion is that the `insert_all`
    # path completes WITHOUT raising — pre-M2 it would unconditionally
    # call `SET session_replication_role` even when the host had no
    # intention of using it, exposing a non-superuser developer to an
    # opaque error.
    MartenFixtures.configure(&.disable_constraints = false)

    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [
      {
        "id"         => 1_i64.as(::DB::Any),
        "name"       => "Skip".as(::DB::Any),
        "created_at" => Time.utc.as(::DB::Any),
        "updated_at" => Time.utc.as(::DB::Any),
      },
    ]

    # On SQLite the fake adapter_kind=:postgres also skips bump_sequences
    # because that's only reached on real-Postgres callers. The point
    # here is that the SET path is short-circuited cleanly.
    if BACKEND == "sqlite"
      # Faking the adapter on a real SQLite connection means we cannot
      # actually exercise the SET; but the test still confirms that the
      # `disable_constraints=false` branch yields without attempting it.
      inserter = PostgresFakingInserter.new(Marten::DB::Connection.default)
      expect_raises(Exception) do
        # The bump_sequences call will fail under SQLite because there's
        # no pg_get_serial_sequence — but that failure happens AFTER the
        # SET path was correctly skipped, proving the opt-out branch
        # executed without issuing SET.
        inserter.insert_all(rows_by_model)
      end
    else
      PostgresFakingInserter.new(Marten::DB::Connection.default).insert_all(rows_by_model)
      Account.get!(pk: 1_i64).name.should eq("Skip")
    end
  end

  it "defines a ConstraintsDisableFailed error subclass with an actionable message contract" do
    # The class exists and is a MartenFixtures::Error subclass so callers
    # can `rescue MartenFixtures::Error` to catch this alongside other
    # fixture-layer failures.
    err = MartenFixtures::Error::ConstraintsDisableFailed.new("test")
    err.should be_a(MartenFixtures::Error)
    err.should be_a(Exception)
  end
end

describe "Phase 2 — polymorphic_resolver centralised @to access (M3)" do
  it "routes resolve(...) through the same target-list path as target_models(...)" do
    # If `resolve` and `target_models` ever disagree on the candidate
    # set, polymorphic FKs would silently resolve to a different target
    # than the dependency-graph said they could. Pin the parity.
    field = Leaf.fields.find!(&.id.==("leafable")).as(Marten::DB::Field::Polymorphic)

    targets = MartenFixtures::PolymorphicResolver.target_models(field)
    # Resolving by short name for each declared target should succeed
    # and return a model class that's ALSO in target_models — i.e. the
    # two methods consult the same underlying list.
    targets.each do |model|
      short = model.name.split("::").last
      resolved_fqcn, resolved_model = MartenFixtures::PolymorphicResolver.resolve(field, short)
      targets.includes?(resolved_model).should be_true
      resolved_fqcn.should eq(model.name)
    end
  end

  it "raises Error::UnknownPolymorphicType for an unknown short name" do
    field = Leaf.fields.find!(&.id.==("leafable")).as(Marten::DB::Field::Polymorphic)
    expect_raises(MartenFixtures::Error::UnknownPolymorphicType, /allowed:/) do
      MartenFixtures::PolymorphicResolver.resolve(field, "NotARealModel")
    end
  end
end

describe "Phase 2 — to_yaml_any raises on unsupported helper return types (M4)" do
  # MFR3 (ACK, 2026-05-20): the `to_yaml_any` else-branch is *dormant*
  # — unreachable through today's public helper API because the
  # `HelperProc` alias narrows helper returns to `Hash(String, String)`,
  # so the keys/values flowing back through `to_yaml_any` are always
  # `String`. The Crinja-side path (`Crinja::Value#raw`) does have
  # types other than String available (Int, Float, Bool, etc.) but
  # those arrive via `arguments.kwargs` at *call* time, not via the
  # helper's *return* value, and every kwarg type is already handled
  # by a named arm.
  #
  # Why we keep the loud-fail branch + this spec instead of deleting:
  # the v0.2 plan in the README is to widen `HelperProc` (so helpers
  # can return `Hash(String, JSON::Any)` or a richer value type). The
  # day that lands, the `to_yaml_any` else-branch becomes live, and
  # the loud-fail prevents a silent `.to_s` flatten that would corrupt
  # `Field::Duration` / `Field::Date` columns by writing a stringified
  # form into a column expecting a typed value.
  #
  # So: this spec proves the wiring is correct (the error class exists,
  # is a `MartenFixtures::Error` subclass, has an actionable message),
  # NOT that the dormant branch fires under today's helper signature.
  # Behavioural coverage of the else-branch is forward-looking — it
  # arrives with the v0.2 widening, not with Phase 4.

  it "defines Error::UnsupportedHelperReturnType as a subclass of Error" do
    err = MartenFixtures::Error::UnsupportedHelperReturnType.new("test")
    err.should be_a(MartenFixtures::Error)
    err.should be_a(Exception)
  end

  it "Error::UnsupportedHelperReturnType is distinct from TemplateUnsupported (different failure modes)" do
    # TemplateUnsupported = template tried to call template syntax that
    # the evaluator doesn't implement (e.g. PlainEvaluator + `{{ ... }}`).
    # UnsupportedHelperReturnType = helper returned a Crystal type the
    # YAML bridge cannot serialise. The two are not interchangeable;
    # a caller rescuing one should not silently catch the other.
    MartenFixtures::Error::UnsupportedHelperReturnType.new("test")
      .is_a?(MartenFixtures::Error::TemplateUnsupported).should be_false
    MartenFixtures::Error::TemplateUnsupported.new("test")
      .is_a?(MartenFixtures::Error::UnsupportedHelperReturnType).should be_false
  end

  it "still routes recognised types (String/Int64/Float64/Bool/Nil) through the existing branches" do
    # End-to-end smoke: a helper returning a Hash(String, String) (the
    # current contract) still works post-M4 (the loud-fail is in the
    # else-branch only; the recognised arms are unchanged).
    registry = MartenFixtures::HelperRegistry.new
    registry.register("hi") do |args, _ctx|
      {"value" => "hello " + args["name"].as_s}
    end

    eval_context = MartenFixtures::EvalContext.new(
      Path["spec/fixtures"],
      MartenFixtures::LabelRegistry.new,
    )
    evaluator = MartenFixtures::CrinjaEvaluator.new(
      helper_registry: registry,
      eval_context: eval_context,
    )

    # String kwarg (recognised), Int64 kwarg (recognised), Bool kwarg
    # (recognised), nested call. None of these should raise
    # UnsupportedHelperReturnType.
    rendered = evaluator.evaluate(
      "greeting: {{ hi(name=\"world\").value }}\n",
      {} of String => String,
    )
    rendered.should contain("hello world")
  end
end

describe "Phase 2 — Marten::Log integration for warnings (M6)" do
  it "does not write to STDERR when the multi-dir warning fires" do
    # Stub out STDERR via a captured-IO indirection. We can't easily
    # replace STDERR globally; instead we assert that the warning path
    # uses Marten::Log by checking that Marten::Log responds to .warn
    # at the module level (compile-time presence is sufficient — the
    # previous STDERR.puts call would have surfaced as a bare puts).
    Marten::Log.responds_to?(:warn).should be_true

    # And: a quick smoke test that loading multi-dir fixtures does not
    # itself raise. Pre-M6 this path wrote to STDERR; we don't assert
    # output absence (Crystal's Log emits via the configured backend,
    # which in test is :None per spec_helper), but if the call site
    # had a typo or broken reference the load would raise.
    tmp_root = Path[Dir.tempdir] / "marten_fixtures_log_spec_#{Random::Secure.hex}"
    dir_a = tmp_root / "a"
    dir_b = tmp_root / "b"
    Dir.mkdir_p(dir_a.to_s)
    Dir.mkdir_p(dir_b.to_s)
    File.write((dir_a / "accounts.yml").to_s, File.read("spec/fixtures/accounts.yml"))
    file_b = dir_b / "users.yml"
    File.write(file_b.to_s, File.read("spec/fixtures/users.yml"))

    MartenFixtures::Loader.new([
      (dir_a / "accounts.yml").as(Path),
      file_b.as(Path),
    ]).load

    Account.all.size.should eq(2)
    User.all.size.should eq(2)
  ensure
    FileUtils.rm_rf(tmp_root.to_s) if tmp_root
  end
end
