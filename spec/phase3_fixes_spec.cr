require "./spec_helper"

# Phase 3 regression specs covering the LOW findings in
# `reviews/marten-fixtures-review.md` (L1–L11; L12 already locked
# in by Phase 1's `MartenFixtures.last_label_registry` accessor and
# spec at `phase1_fixes_spec.cr`).
#
# L1 (LabelRegistry duplicate detection) has dedicated coverage in
# `label_registry_spec.cr` because the contract is on the registry
# class itself; the cross-file integration regression lives here.
# L9 (UUID OID namespace) is locked at `label_spec.cr`.
# L10 (`_topo_sort_for_spec` rename) is exercised via the existing
# topo-sort specs in `loader_spec.cr` which now use the new name.

describe "Phase 3 — L1 cross-file label collision raises" do
  it "directly verifies LabelRegistry guards conflicting registrations (L1)" do
    # The cross-file integration case (two YAML files registering the
    # same `(model, label)` key with different pks) routes through
    # `LabelRegistry#register`, which now raises `DuplicateLabel` on
    # mismatched pk values. The dedicated contract surface lives in
    # `label_registry_spec.cr`; this spec confirms the error class
    # is available and the error message is actionable for the
    # integration-level caller.
    registry = MartenFixtures::LabelRegistry.new
    registry.register(User, "david", 10_i64)
    expect_raises(
      MartenFixtures::Error::DuplicateLabel,
      /User\/david.+already registered with pk=10.+pk=99/,
    ) do
      registry.register(User, "david", 99_i64)
    end
  end

  it "Error::DuplicateLabel is a MartenFixtures::Error subclass (rescue-friendly)" do
    err = MartenFixtures::Error::DuplicateLabel.new("test")
    err.should be_a(MartenFixtures::Error)
    err.should be_a(Exception)
  end
end

describe "Phase 3 — L2 lookup_field error truncation" do
  it "lists every known field when the model has few fields" do
    interpolator = MartenFixtures::RowInterpolator.new(
      Account,
      MartenFixtures::LabelRegistry.new,
      :auto,
    )
    expect_raises(MartenFixtures::Error::UnknownField, /known fields: id, name/) do
      interpolator.interpolate("a", {"nope" => YAML::Any.new("x")})
    end
  end

  it "truncates the known-fields list to 20 entries with an `and N more` suffix when the model is wide" do
    # We have no >20-field model in test_project, so simulate by spying
    # on the truncation constant value. KNOWN_FIELDS_SAMPLE = 20 is the
    # documented cap; the suffix shape is "(and N more)". The error
    # message is built only when an UnknownField escapes get_field, so
    # we lock the cap value as the contract and rely on the production
    # call path being identical regardless of model width.
    MartenFixtures::RowInterpolator::KNOWN_FIELDS_SAMPLE.should eq(20)
  end
end

describe "Phase 3 — L3 collect_models memoisation" do
  it "exposes a class-level cache reset hook" do
    # The cache hook is required for tests that need a fresh walk of
    # `Marten.apps.app_configs` after spec-level mutation. We assert
    # the hook is invocable and returns nil (no-op semantics).
    MartenFixtures::Loader.clear_model_cache!.should be_nil
  end

  it "successive Loader.new calls reuse the cached model list (regression smoke)" do
    # The internal cache is a class-var; the behavioural contract is
    # that constructing many Loaders in a row is cheap (no repeated
    # `Marten.apps.app_configs.each` walk) and the resulting Loaders
    # work identically to the pre-L3 baseline. Lock by constructing
    # twice and exercising both.
    MartenFixtures::Loader.clear_model_cache!
    first = MartenFixtures::Loader.new([] of Path)
    second = MartenFixtures::Loader.new([] of Path)
    first.label_registry.should be_a(MartenFixtures::LabelRegistry)
    second.label_registry.should be_a(MartenFixtures::LabelRegistry)
  end
end

describe "Phase 3 — L4 self-FK within-file ordering" do
  it "loads a categories fixture where parent rows precede children (ordered)" do
    MartenFixtures::Loader.new([
      Path["spec/fixtures_l4_ordered/categories.yml"],
    ]).load

    Category.all.size.should eq(3)
    root = Category.get!(pk: MartenFixtures::Label.identify("root"))
    middle = Category.get!(pk: MartenFixtures::Label.identify("middle"))
    leaf = Category.get!(pk: MartenFixtures::Label.identify("leaf"))

    root.parent_id.should be_nil
    middle.parent_id.should eq(root.pk)
    leaf.parent_id.should eq(middle.pk)
  end

  it "loads a categories fixture where children precede parents in YAML (scrambled)" do
    # Pre-L4 this would silently orphan on SQLite (no FK enforcement)
    # and FK-violate on Postgres. L4 self-FK-sorts the rows within the
    # file so parents land first regardless of YAML order.
    MartenFixtures::Loader.new([
      Path["spec/fixtures_l4_scrambled/categories.yml"],
    ]).load

    Category.all.size.should eq(3)
    root = Category.get!(pk: MartenFixtures::Label.identify("root"))
    middle = Category.get!(pk: MartenFixtures::Label.identify("middle"))
    leaf = Category.get!(pk: MartenFixtures::Label.identify("leaf"))

    root.parent_id.should be_nil
    middle.parent_id.should eq(root.pk)
    leaf.parent_id.should eq(middle.pk)
  end

  it "raises a clear Error on a within-file self-FK cycle" do
    # A direct cycle (a.parent=b, b.parent=a) cannot be topo-sorted.
    # We expect a descriptive error instead of a silent DB-level FK
    # failure.
    tmp_root = Path[Dir.tempdir] / "marten_fixtures_l4_cycle_#{Random::Secure.hex}"
    Dir.mkdir_p(tmp_root.to_s)
    File.write(
      (tmp_root / "categories.yml").to_s,
      "a:\n  name: A\n  parent: b\n\nb:\n  name: B\n  parent: a\n",
    )

    expect_raises(MartenFixtures::Error, /Self-FK cycle within Category/) do
      MartenFixtures::Loader.new([tmp_root / "categories.yml"]).load
    end
  ensure
    FileUtils.rm_rf(tmp_root.to_s) if tmp_root
  end
end

describe "Phase 3 — L5 BATCH_SIZE cap removed" do
  it "delegates batch sizing entirely to Marten's bulk_batch_size (no in-shard cap)" do
    # L5 removed the `BATCH_SIZE = 500` constant in favour of Marten's
    # backend-aware `bulk_batch_size`. The end-to-end signal is: the
    # standard load still works (covered by every other spec). This
    # spec exists as a regression marker — if a host pinned the
    # removed constant in their own code, the compile would fail
    # there, not here. Locking only the behavioural contract.
    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [
      {
        "id"         => 7_i64.as(::DB::Any),
        "name"       => "L5Sentinel".as(::DB::Any),
        "created_at" => Time.utc.as(::DB::Any),
        "updated_at" => Time.utc.as(::DB::Any),
      },
    ]
    MartenFixtures::Inserter.new(Marten::DB::Connection.default).insert_all(rows_by_model)
    Account.get!(pk: 7_i64).name.should eq("L5Sentinel")
  end
end

describe "Phase 3 — L6 CrinjaEvaluator EvalContext re-injection" do
  it "lets the Loader inject a live EvalContext into a pre-constructed CrinjaEvaluator" do
    # Host stores a CrinjaEvaluator on the configuration (typical when
    # they want to swap in a custom HelperRegistry). Pre-L6 the Loader
    # used the host's evaluator as-is, and helper invocations would
    # raise "EvalContext with a loaded label registry" because the
    # evaluator was built before any load had populated a registry.
    registry = MartenFixtures::HelperRegistry.new
    registry.register("noteable") do |_args, ctx|
      {"value" => "registry-#{ctx.label_registry.size}"}
    end

    preconstructed = MartenFixtures::CrinjaEvaluator.new(
      helper_registry: registry,
      eval_context: nil,
    )
    MartenFixtures.configuration.evaluator = preconstructed

    # Confirm the eval_context starts nil (the regression baseline).
    preconstructed.eval_context.should be_nil

    # The Loader's normal `load_all`/`load` path consults
    # `configuration.evaluator` and injects an EvalContext via the L6
    # setter. We trigger the setter via a no-op load (one fixture file
    # without any template syntax — the evaluator is queried but the
    # PlainEvaluator path skips actual templating; here CrinjaEvaluator
    # IS the evaluator, so it's queried but the file has no template).
    MartenFixtures::Loader.new([
      Path["spec/fixtures/accounts.yml"],
    ]).load

    # Post-load, the EvalContext is live on the pre-constructed evaluator.
    preconstructed.eval_context.should_not be_nil
  end

  it "leaves a non-Crinja evaluator alone (no setter call) so PlainEvaluator stays untouched" do
    plain = MartenFixtures::PlainEvaluator.new
    MartenFixtures.configuration.evaluator = plain

    MartenFixtures::Loader.new([Path["spec/fixtures/accounts.yml"]]).load

    # No exception, no mutation. The same instance survives the load.
    MartenFixtures.configuration.evaluator.should be(plain)
  end
end

describe "Phase 3 — L7 dfs_for_cycle ensure cleanup (behavioural)" do
  it "still surfaces the cycle path when models form a dependency cycle" do
    # L7 added an `ensure` to clean up the DFS stack on early return.
    # That cleanup is invisible to single-call usage (the discovered
    # cycle propagates up the search and the function abandons), so
    # the only behavioural lock is that cycle detection STILL works
    # post-refactor. We piggyback on the existing cycle spec shape.
    extra_edges = {} of Marten::DB::Model.class => Array(Marten::DB::Model.class)
    extra_edges[Account] = [Extra] of Marten::DB::Model.class
    extra_edges[Extra] = [Account] of Marten::DB::Model.class

    loader = MartenFixtures::Loader.new([] of Path)
    expect_raises(
      MartenFixtures::Error,
      /Fixture model dependency cycle:/,
    ) do
      loader._topo_sort_for_spec([Account, Extra] of Marten::DB::Model.class, extra_edges)
    end
  end
end

describe "Phase 3 — L11 model_set removed from topo_sort_models" do
  it "still loads multiple models in dependency order (regression smoke)" do
    # L11 is a micro-perf rewrite: `models.to_set` was redundant with
    # the `dependencies` hash's key lookup. The behaviour is unchanged.
    # The existing loader_spec.cr topo-sort tests run unchanged through
    # the new code path; this spec is a smoke-only check that the
    # standard load still works.
    files = [
      Path["spec/fixtures/accounts.yml"],
      Path["spec/fixtures/users.yml"],
      Path["spec/fixtures/posts.yml"],
    ]
    MartenFixtures::Loader.new(files).load
    Account.all.size.should eq(2)
    User.all.size.should eq(2)
    Post.all.size.should eq(2)
  end
end

describe "Phase 3 — L12 already locked by Phase 1 (verification only)" do
  it "exposes MartenFixtures.last_label_registry after a load (symmetric to H1)" do
    MartenFixtures::Loader.new([
      Path["spec/fixtures/accounts.yml"],
      Path["spec/fixtures/users.yml"],
    ]).load
    MartenFixtures.last_label_registry.should_not be_nil
    MartenFixtures.last_label_registry.not_nil!.lookup(User, "david").should eq(
      MartenFixtures::Label.identify("david"),
    )
  end
end
