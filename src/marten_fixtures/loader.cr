require "yaml"

module MartenFixtures
  # Orchestrates the two-pass fixture load.
  #
  # Pass 1 walks every file, derives the target model from the file path,
  # parses the YAML, and registers a deterministic CRC32-derived PK for
  # each label in the `LabelRegistry`. Pass 1 does NOT render templates —
  # the top-level row labels (the only keys read in pass 1) are static.
  #
  # Pass 2 renders each file through the template evaluator (so helpers
  # like `bcrypt(...)` fire), parses the rendered YAML, interpolates each
  # row through `RowInterpolator`, and bulk-inserts everything inside a
  # single transaction via `Inserter`.
  class Loader
    private alias ParsedFile = NamedTuple(
      file: FixtureFile,
      raw: String,
      rows: Hash(String, Hash(String, YAML::Any)),
    )

    @models : Array(Marten::DB::Model.class)
    @expanded_file_dirs : Array(Path)
    @expanded_configured_path : Path

    # L8: every path-derived value (`@expanded_configured_path`,
    # `@expanded_file_dirs`) is computed once at construction time
    # using the CWD live at that instant. The `Configuration#fixtures_path`
    # captured here is the value at construction time too — mutating
    # `MartenFixtures.configuration.fixtures_path` (or the supplied
    # `@config`) between `Loader.new` and `loader.load` does NOT
    # change the path used for fixtures resolution or the `EvalContext`
    # that helpers see. This is intentional: parallel test runners or
    # programs that `Dir.cd` between construction and load would
    # otherwise see CWD-corrupted paths.
    #
    # Other Configuration properties (`timestamp_policy`, `evaluator`,
    # `disable_constraints`) are still read from `@config` at load time,
    # so a quick mid-flight tweak of those WILL take effect. To pin a
    # full Configuration snapshot, construct a fresh `Configuration`
    # locally and pass it explicitly.
    def initialize(
      @files : Array(Path),
      @config : Configuration = MartenFixtures.configuration,
      @helper_registry : HelperRegistry = HelperRegistry.global,
    )
      @label_registry = LabelRegistry.new
      @parsed = [] of ParsedFile
      @models = collect_models
      # Resolve every path against the *current* working directory once at
      # construction time. `Path#expand` consults `Dir.current`, so doing
      # this lazily would attribute paths to whatever CWD happens to be
      # live when the evaluator is first built (parallel test runners,
      # programs that `Dir.cd`, etc.).
      @expanded_configured_path = @config.fixtures_path.expand
      @expanded_file_dirs = @files.map(&.parent.expand)
      @expanded_file_dirs.uniq!
    end

    getter label_registry : LabelRegistry

    def load : Nil
      pass_one_register_labels
      pass_two_interpolate_and_insert
      # Publish the populated registry so spec-side `Accessors#fixture`
      # can resolve explicit-`id:` rows (H1 / L12). Last load wins; tests
      # that load fresh fixtures per example reset on the next `load`.
      MartenFixtures.last_label_registry = @label_registry
    end

    private def pass_one_register_labels : Nil
      @files.each do |path|
        raw = File.read(path)
        rows = parse_rows(raw, path)
        fixture_file = FixtureFile.new(path, @models)
        pk_field = fixture_file.model_class.fields.find!(&.primary_key?)
        pk_column = pk_field.db_column!

        rows.each do |label, attrs|
          # H1: when the YAML row provides an explicit PK value (e.g.
          # `id: 999`), register THAT value as the label's PK so that
          # cross-fixture FK references via the label resolve to the
          # explicit value (not the CRC32-derived placeholder). The
          # explicit-PK contract is: an explicit `id:` value is preserved
          # at insert time AND used as the FK target for label references.
          explicit_pk = explicit_pk_for(attrs, pk_field, pk_column)
          pk = explicit_pk || Label.identify(label, pk_field)
          @label_registry.register(fixture_file.model_class, label, pk)
        end

        @parsed << {file: fixture_file, raw: raw, rows: rows}
      end
    end

    # H1: returns an explicit PK from the YAML row's `<pk_column>` key if
    # present (typically `id:`), coerced into the union expected by the
    # label registry. Returns `nil` if the row doesn't carry an explicit
    # PK (the common case — the loader will derive one from `Label.identify`).
    private def explicit_pk_for(
      attrs : Hash(String, YAML::Any),
      pk_field : Marten::DB::Field::Base,
      pk_column : String,
    ) : (Int64 | String)?
      explicit = attrs[pk_column]?
      return nil if explicit.nil?

      raw = explicit.raw
      case raw
      when Nil
        nil
      when ::Int
        raw.to_i64.as(Int64 | String)
      when ::String
        if pk_field.is_a?(Marten::DB::Field::UUID)
          raw.as(Int64 | String)
        elsif integer_pk_field?(pk_field)
          # Integer PK field — allow YAML strings that parse as integers
          # (e.g. `id: "42"`) so an over-quoted YAML literal still maps
          # correctly to the underlying Int64 column.
          if as_int = raw.to_i64?
            as_int.as(Int64 | String)
          else
            raise Error.new(
              "Explicit primary key #{raw.inspect} on integer-PK field #{pk_field.id} " \
              "must be parseable as Int64; got a String that #{raw.inspect}.to_i64? returned nil for."
            )
          end
        else
          # MFR5: String-PK fields (non-UUID) preserve the YAML string
          # verbatim. Pre-fix the loader unconditionally `to_i64?`-coerced
          # integer-looking strings, so `id: "42"` on a `:string` PK column
          # was silently stored as `42_i64` and mismatched the column type.
          # The label registry and the row inserter both round-trip the
          # value as-is from here on.
          raw.as(Int64 | String)
        end
      else
        raise Error.new(
          "Explicit primary key #{raw.inspect} on row in #{pk_field.id} must be an integer or string"
        )
      end
    end

    # MFR5: integer PK field? Marten's integer field hierarchy is
    # `BigInt` (the standard auto-PK choice) and `Int` (32-bit). Both
    # back an Int64-castable column, so we coerce integer-looking
    # strings on both. UUID and String PKs are handled in the caller.
    private def integer_pk_field?(pk_field : Marten::DB::Field::Base) : Bool
      pk_field.is_a?(Marten::DB::Field::BigInt) || pk_field.is_a?(Marten::DB::Field::Int)
    end

    private def pass_two_interpolate_and_insert : Nil
      rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
      evaluator = evaluator_for(@label_registry)

      @parsed.each do |entry|
        rendered_rows = render_rows(evaluator, entry)
        interpolator = RowInterpolator.new(
          entry[:file].model_class,
          @label_registry,
          @config.timestamp_policy,
        )

        # L4: when the file's model has a self-FK (ManyToOne/OneToOne
        # → itself), within-file row order matters: a child row whose
        # parent ref points at a sibling label that appears later in
        # the YAML would FK-violate on Postgres (and silently orphan on
        # SQLite, where FKs aren't enforced). Topo-sort the rows by
        # self-FK dependency before interpolating so parent rows always
        # precede children, regardless of the order they were typed
        # into the YAML.
        ordered_rows = topo_sort_rows_for_self_fk(entry[:file].model_class, rendered_rows)

        ordered_rows.each do |label, raw_attrs|
          row = interpolator.interpolate(label, raw_attrs)
          rows_by_model[entry[:file].model_class] ||= [] of Hash(String, ::DB::Any)
          rows_by_model[entry[:file].model_class] << row
        end
      end

      return if rows_by_model.empty?

      ordered = topo_sort_models(rows_by_model.keys)
      sorted_rows = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
      ordered.each { |model| sorted_rows[model] = rows_by_model[model] }

      connection = Marten::DB::Connection.default
      # MFR2: pass `@config` through so the Inserter consults the *loader's*
      # Configuration (not the module-global) for `disable_constraints?` —
      # restoring the documented per-loader override contract.
      # MFR1 / MFR4: routed through `build_inserter` so spec subclasses
      # can return a spy `Inserter` and assert on the SET / bulk_insert
      # call order without monkey-patching the production code path.
      build_inserter(connection).insert_all(sorted_rows)
    end

    # :nodoc:
    protected def build_inserter(connection : Marten::DB::Connection::Base) : Inserter
      Inserter.new(connection, @config)
    end

    # Test-only hook to invoke the private topological sort with a
    # synthesised dependency graph (so cycles and two-FK-to-same-parent
    # scenarios can be exercised without adding production models).
    # `extra_edges` lets a spec inject `model -> dep` edges that aren't
    # present in the real `deps_for` output.
    #
    # L10: the leading underscore is the Crystal community convention
    # for "really internal, do not call from non-test code." Combined
    # with `:nodoc:` (hides from API doc tools) and the explicit
    # docstring, an accidental host-side call now stands out at the
    # call site.
    #
    # :nodoc:
    def _topo_sort_for_spec(
      models : Array(Marten::DB::Model.class),
      extra_edges : Hash(Marten::DB::Model.class, Array(Marten::DB::Model.class)) = {} of Marten::DB::Model.class => Array(Marten::DB::Model.class),
    ) : Array(Marten::DB::Model.class)
      @spec_extra_edges = extra_edges
      result = topo_sort_models(models)
      result
    ensure
      @spec_extra_edges = nil
    end

    @spec_extra_edges : Hash(Marten::DB::Model.class, Array(Marten::DB::Model.class))? = nil

    # Topologically sorts the given models so that any model with a
    # ManyToOne/OneToOne/Polymorphic dependency on another model in the
    # set is inserted *after* its dependencies. Uses Kahn's algorithm.
    # Raises `Error` if the dependency graph contains a cycle; the error
    # message includes the actual cycle path (e.g. "A -> B -> C -> A")
    # rather than just the set of unsorted models.
    #
    # NOTE: self-referential FKs (e.g. `manager :many_to_one, to: Employee`)
    # are skipped — they do not affect cross-model ordering, but they DO
    # mean parent rows must precede child rows *within* the same model's
    # fixture YAML. Row-level ordering is the user's responsibility.
    private def topo_sort_models(
      models : Array(Marten::DB::Model.class),
    ) : Array(Marten::DB::Model.class)
      dependencies = {} of Marten::DB::Model.class => Set(Marten::DB::Model.class)
      # `dependents` uses Set, not Array — a model with two FKs to the
      # same parent (e.g. `created_by`, `updated_by` → User) must NOT
      # appear twice in `dependents[User]`, or Kahn's inner loop will
      # double-decrement and double-enqueue, producing a spurious cycle
      # error.
      dependents = {} of Marten::DB::Model.class => Set(Marten::DB::Model.class)

      models.each do |model|
        dependencies[model] = Set(Marten::DB::Model.class).new
        dependents[model] = Set(Marten::DB::Model.class).new
      end

      models.each do |model|
        deps_for(model).each do |dep|
          # L11: `dependencies.has_key?(dep)` is the membership probe;
          # we no longer pre-allocate a separate `model_set = models.to_set`
          # because the hash we just built (keyed by the same models)
          # already gives us O(1) lookup. Saves one Set allocation per
          # load (small, but trivially worth it).
          next unless dependencies.has_key?(dep)
          next if dep == model
          dependencies[model] << dep
          dependents[dep] << model
        end
      end

      # Kahn: start with models that have no in-set dependencies.
      ready = models.select { |model| dependencies[model].empty? }
      ordered = [] of Marten::DB::Model.class

      until ready.empty?
        model = ready.shift
        ordered << model
        dependents[model].each do |dependent|
          dependencies[dependent].delete(model)
          ready << dependent if dependencies[dependent].empty?
        end
      end

      if ordered.size != models.size
        raise Error.new(cycle_error_message(models, ordered, dependencies))
      end

      ordered
    end

    # Builds an actionable error message when Kahn's algorithm fails to
    # consume the entire graph. Walks the surviving dependency edges with
    # DFS to find an actual cycle path; reports it edge-by-edge so the
    # user can see which FK closes the loop.
    private def cycle_error_message(
      models : Array(Marten::DB::Model.class),
      ordered : Array(Marten::DB::Model.class),
      dependencies : Hash(Marten::DB::Model.class, Set(Marten::DB::Model.class)),
    ) : String
      remaining = models - ordered
      cycle = find_cycle(remaining, dependencies)
      remaining_names = remaining.map(&.name).join(", ")
      if cycle && cycle.size >= 2
        path = cycle.map(&.name).join(" -> ")
        suffix = remaining.size > cycle.size ? " (other cycles may also be present among #{remaining_names})" : ""
        "Fixture model dependency cycle: #{path}#{suffix}"
      else
        "Fixture model dependency cycle among: #{remaining_names}"
      end
    end

    # DFS from each remaining node to find a cycle path. Returns an array
    # of models forming the cycle (with the start node repeated at the
    # end, e.g. `[A, B, C, A]`) or nil if no cycle is found.
    private def find_cycle(
      remaining : Array(Marten::DB::Model.class),
      dependencies : Hash(Marten::DB::Model.class, Set(Marten::DB::Model.class)),
    ) : Array(Marten::DB::Model.class)?
      remaining.each do |start|
        path = [] of Marten::DB::Model.class
        on_stack = Set(Marten::DB::Model.class).new
        result = dfs_for_cycle(start, dependencies, path, on_stack, remaining.to_set)
        return result if result
      end
      nil
    end

    private def dfs_for_cycle(
      node : Marten::DB::Model.class,
      dependencies : Hash(Marten::DB::Model.class, Set(Marten::DB::Model.class)),
      path : Array(Marten::DB::Model.class),
      on_stack : Set(Marten::DB::Model.class),
      restrict_to : Set(Marten::DB::Model.class),
    ) : Array(Marten::DB::Model.class)?
      path << node
      on_stack << node
      # L7: belt-and-suspenders cleanup. The current single-call usage
      # in `find_cycle` propagates the discovered cycle straight up the
      # stack and abandons the search, so a "dirty" `path`/`on_stack`
      # never had a visible effect. The `ensure` exists so that a
      # future caller invoking `dfs_for_cycle` repeatedly with the same
      # accumulators (or wrapping it in a continuation-style search)
      # can't accidentally inherit stale state.
      cycle : Array(Marten::DB::Model.class)? = nil
      begin
        dependencies[node].each do |dep|
          next unless restrict_to.includes?(dep)
          if on_stack.includes?(dep)
            start_index = path.index!(dep)
            cycle = path[start_index..] + [dep]
            break
          end
          next if path.includes?(dep)
          result = dfs_for_cycle(dep, dependencies, path, on_stack, restrict_to)
          if result
            cycle = result
            break
          end
        end
        cycle
      ensure
        on_stack.delete(node)
        path.pop
      end
    end

    # L4: returns the rows of `rendered_rows` in self-FK-dependency order.
    # If the model has no self-FK fields, the input is returned unchanged
    # (preserving YAML order). Otherwise, builds a row-level dep graph
    # (row B depends on row A if B's self-FK column references the label
    # of row A) and Kahn-sorts. A cycle (e.g. A.parent=B, B.parent=A)
    # raises with the cycle path so the author gets a clear error
    # instead of a silent DB-level failure.
    private def topo_sort_rows_for_self_fk(
      model_class : Marten::DB::Model.class,
      rendered_rows : Hash(String, Hash(String, YAML::Any)),
    ) : Array({String, Hash(String, YAML::Any)})
      self_fk_field_ids = self_fk_field_ids_for(model_class)
      original = rendered_rows.to_a
      return original if self_fk_field_ids.empty?

      label_set = rendered_rows.keys.to_set
      dependencies = {} of String => Set(String)
      dependents = {} of String => Set(String)
      rendered_rows.each_key do |label|
        dependencies[label] = Set(String).new
        dependents[label] = Set(String).new
      end

      rendered_rows.each do |label, attrs|
        self_fk_field_ids.each do |key|
          ref = attrs[key]?
          next if ref.nil?
          raw = ref.raw
          next unless raw.is_a?(::String)
          # Only treat the value as a within-file label ref when there
          # actually IS a sibling row by that name. (A self-FK can also
          # legitimately reference a row that's already in the DB from
          # a prior load, in which case we leave the order alone.)
          next unless label_set.includes?(raw)
          next if raw == label
          dependencies[label] << raw
          dependents[raw] << label
        end
      end

      ready = original.select { |(label, _)| dependencies[label].empty? }.map(&.[0])
      label_order = [] of String
      until ready.empty?
        current = ready.shift
        label_order << current
        dependents[current].each do |child|
          dependencies[child].delete(current)
          ready << child if dependencies[child].empty?
        end
      end

      if label_order.size != rendered_rows.size
        unsorted = rendered_rows.keys.reject { |label| label_order.includes?(label) }
        raise Error.new(
          "Self-FK cycle within #{model_class.name} fixture rows among: " \
          "#{unsorted.join(", ")}. Self-FK references must form an acyclic graph " \
          "(parent rows must precede children in the dependency sense, not the " \
          "YAML-file sense)."
        )
      end

      label_order.map { |label| {label, rendered_rows[label]} }
    end

    # Returns every YAML key that could carry a self-FK reference for
    # the given model — both the relation name (`parent`) and the
    # underlying column id (`parent_id`). Fixture YAML by convention
    # uses the relation name (so a row reads `parent: root` rather
    # than `parent_id: root`), but we also accept the id form so a
    # YAML file that's already been mechanically translated still
    # gets the within-file sort.
    private def self_fk_field_ids_for(model_class : Marten::DB::Model.class) : Array(String)
      keys = [] of String
      model_class.fields.each do |field|
        case field
        when Marten::DB::Field::ManyToOne, Marten::DB::Field::OneToOne
          next unless field.related_model == model_class
          keys << field.relation_name
          keys << field.id unless field.id == field.relation_name
        end
      end
      keys
    end

    private def deps_for(model : Marten::DB::Model.class) : Array(Marten::DB::Model.class)
      deps = [] of Marten::DB::Model.class
      model.fields.each do |field|
        case field
        when Marten::DB::Field::ManyToOne, Marten::DB::Field::OneToOne
          deps << field.related_model
        when Marten::DB::Field::Polymorphic
          PolymorphicResolver.target_models(field).each { |target| deps << target }
        end
      end
      if extra = @spec_extra_edges
        extra[model]?.try(&.each { |dep| deps << dep })
      end
      deps
    end

    private def render_rows(
      evaluator : Evaluator,
      entry : ParsedFile,
    ) : Hash(String, Hash(String, YAML::Any))
      return entry[:rows] if evaluator.is_a?(PlainEvaluator) && !template_syntax?(entry[:raw])

      rendered_source = evaluator.evaluate(entry[:raw], {} of String => String)
      parse_rows(rendered_source, entry[:file].path)
    end

    private def parse_rows(source : String, path : Path) : Hash(String, Hash(String, YAML::Any))
      parsed = YAML.parse(source)
      raw = parsed.raw
      return {} of String => Hash(String, YAML::Any) if raw.nil?

      unless raw.is_a?(Hash)
        raise Error.new("Fixture file #{path} must contain a YAML mapping at the top level")
      end

      rows = {} of String => Hash(String, YAML::Any)
      raw.each do |key, value|
        label = key.as_s
        attrs_raw = value.raw
        unless attrs_raw.is_a?(Hash)
          raise Error.new(
            "Fixture row #{label.inspect} in #{path} must be a YAML mapping of attributes"
          )
        end

        attrs = {} of String => YAML::Any
        attrs_raw.each { |k, v| attrs[k.as_s] = v }
        rows[label] = attrs
      end
      rows
    end

    private def evaluator_for(label_registry : LabelRegistry) : Evaluator
      if existing = @config.evaluator
        # L6: when the host pre-configured a `CrinjaEvaluator` (e.g. so
        # they could swap in a non-global HelperRegistry), the Loader
        # injects a live EvalContext into it via the setter. Without
        # this, the evaluator's helper procs would raise the "EvalContext
        # with a loaded label registry" error on first invocation
        # because the pre-construction-time context was nil. Other
        # evaluator types (e.g. PlainEvaluator, a user's custom
        # implementation) are left untouched.
        if existing.is_a?(CrinjaEvaluator)
          existing.eval_context = EvalContext.new(eval_context_path, label_registry)
        end
        return existing
      end

      eval_context = EvalContext.new(eval_context_path, label_registry)
      CrinjaEvaluator.new(helper_registry: @helper_registry, eval_context: eval_context)
    end

    # The `fixtures_path` exposed to helpers should reflect the files
    # actually being loaded, not the configured default.
    #
    # All path expansion happens at `Loader` construction time (so CWD
    # changes after `Loader.new` do not corrupt the result).
    #
    # - Single directory → return it.
    # - All dirs nested under the configured root → return the configured
    #   root (the typical `load_all` case where a nested subdir is just
    #   part of the fixtures tree).
    # - Otherwise → return the least-common-ancestor of the loaded file
    #   directories, and emit a STDERR warning that the files span dirs
    #   outside the configured root.
    private def eval_context_path : Path
      return @expanded_configured_path if @expanded_file_dirs.empty?
      return @expanded_file_dirs.first if @expanded_file_dirs.size == 1

      configured_str = @expanded_configured_path.to_s
      under_configured = @expanded_file_dirs.all?(&.to_s.starts_with?(configured_str))
      return @expanded_configured_path if under_configured

      lca = least_common_ancestor(@expanded_file_dirs)
      # M6: route the warning through Marten's central `Log` so test
      # runners that fail on stderr writes don't misclassify the benign
      # multi-dir notification. Hosts can adjust verbosity via
      # `Marten.settings.log_level` or scope a per-source filter to
      # the `marten` logger source (we don't `.for("marten-fixtures")`
      # to keep the namespace shallow — the message body already
      # carries the `[marten-fixtures]` prefix for grep-ability).
      Marten::Log.warn do
        "[marten-fixtures] loaded files span multiple directories " \
        "(#{@expanded_file_dirs.map(&.to_s).join(", ")}); EvalContext.fixtures_path " \
        "falls back to least-common-ancestor #{lca}"
      end
      lca
    end

    # Returns the deepest path that is a prefix of every input path.
    # Inputs are expected to be already-expanded absolute paths.
    private def least_common_ancestor(paths : Array(Path)) : Path
      parts_lists = paths.map(&.parts)
      shared = [] of String
      max = parts_lists.min_of(&.size)
      max.times do |i|
        candidate = parts_lists.first[i]
        break unless parts_lists.all? { |parts| parts[i] == candidate }
        shared << candidate
      end
      shared.empty? ? Path["/"] : Path[shared.join(File::SEPARATOR)]
    end

    private def template_syntax?(source : String) : Bool
      source.includes?("{{") || source.includes?("{%")
    end

    # L3: memoised on the class so that test suites with a
    # `before_each` `Loader.new(...).load` don't re-walk every app's
    # model list on every example. The list is invariant at runtime
    # (Marten apps load at boot), so caching is safe; `clear_model_cache!`
    # exists for the rare test case that wants to confirm a custom
    # `Marten.apps` configuration is picked up after spec-level mutation.
    @@all_models : Array(Marten::DB::Model.class)? = nil

    # :nodoc:
    def self.clear_model_cache! : Nil
      @@all_models = nil
    end

    private def collect_models : Array(Marten::DB::Model.class)
      cached = @@all_models
      return cached if cached
      models = [] of Marten::DB::Model.class
      Marten.apps.app_configs.each do |app_config|
        app_config.models.each { |model| models << model }
      end
      @@all_models = models
      models
    end
  end
end
