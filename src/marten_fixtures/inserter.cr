module MartenFixtures
  # Runs the DB-insert pass of the fixture load: disables foreign-key
  # constraints for the duration, bulk-inserts rows per model, and (on
  # Postgres) advances each table's sequence past the highest inserted PK
  # so subsequent application-level `create` calls don't collide.
  #
  # The whole body runs inside `connection.transaction` so every nested
  # `connection.open` reuses the same physical connection — necessary on
  # Postgres for `SET session_replication_role` to apply to the bulk
  # inserts that follow. SQLite's `PRAGMA foreign_keys` is a no-op inside
  # a transaction, so on SQLite this code relies on the two-pass loader
  # producing FK-correct insert order rather than on constraint disable.
  class Inserter
    # MFR2: `@config` is threaded through from `Loader.new` so that the
    # `disable_constraints?` opt-out is read from the *loader's* Configuration
    # (the one the caller passed to `Loader.new`), not from the module-global
    # `MartenFixtures.configuration`. Callers constructing an `Inserter`
    # directly (e.g. specs) may pass a custom Configuration to override the
    # global; the default keeps the prior behaviour of reading the global.
    def initialize(
      @connection : Marten::DB::Connection::Base,
      @config : Configuration = MartenFixtures.configuration,
    )
    end

    def insert_all(rows_by_model : Hash(Marten::DB::Model.class, Array(Hash(String, ::DB::Any)))) : Nil
      @connection.transaction do
        with_constraints_disabled do
          rows_by_model.each do |model, rows|
            insert_for_model(model, rows)
          end
          bump_sequences_for(rows_by_model.keys) if postgres?
        end
      end
    end

    # MFR1: extracted from `insert_all` so spec subclasses that fake
    # `adapter_kind == :postgres` on a real SQLite connection can stub
    # the Postgres-only sequence bump (which would call
    # `pg_get_serial_sequence` on the wrong backend) without re-implementing
    # the surrounding constraint-disable / transaction scaffolding. The
    # production path is unchanged: it dispatches to `bump_sequences`.
    protected def bump_sequences_for(models : Array(Marten::DB::Model.class)) : Nil
      bump_sequences(models)
    end

    private def insert_for_model(model : Marten::DB::Model.class, rows : Array(Hash(String, ::DB::Any))) : Nil
      return if rows.empty?
      # H2: normalize heterogeneous row shapes (some rows supplying an
      # optional column that others omit) to a shared column set before
      # handing to bulk_insert. Marten's bulk_insert derives the column
      # list from `rows.first.keys` and `flat_map(&.values)`; if rows
      # disagree on which keys are present, values shift into the wrong
      # columns (or the bind count mismatches and Postgres raises). We
      # compute the union of all keys in the batch, fill missing keys
      # with the field's default (or nil if no default is configured),
      # and emit rows in a consistent key order.
      normalized = normalize_rows(model, rows)
      columns = normalized.first.size
      # L5: defer batch sizing entirely to Marten's backend-aware
      # `bulk_batch_size`. SQLite's 999-parameter ceiling is enforced
      # there; Postgres can comfortably handle several thousand rows
      # per statement and was previously bottlenecked at 500 by an
      # arbitrary in-shard cap.
      batch_size = @connection.bulk_batch_size(rows.size, columns)
      normalized.each_slice(batch_size) do |slice|
        bulk_insert_slice(model, slice)
      end
    end

    # MFR4: extracted as a protected method so spec subclasses can spy on
    # the per-slice row order handed to Marten's `bulk_insert` (asserts
    # that within-file topo-sort produces parent-before-child order). The
    # production call path is unchanged.
    protected def bulk_insert_slice(
      model : Marten::DB::Model.class,
      slice : Array(Hash(String, ::DB::Any)),
    ) : Nil
      @connection.bulk_insert(model.db_table, slice)
    end

    # H2: returns rows where every entry has the same key set (the union
    # across the input batch), with missing keys filled from the field's
    # configured `default` (coerced via `to_db`) or nil. Key insertion
    # order is preserved as the order in which a key was first seen — so
    # if every row in a homogeneous batch already shares a shape, the
    # output is a no-op shape-wise. (Hash equality on keys is order-
    # insensitive, but bulk_insert's column list is derived from
    # `rows.first.keys`, so we still rewrite each hash to share the
    # canonical key order.)
    private def normalize_rows(
      model : Marten::DB::Model.class,
      rows : Array(Hash(String, ::DB::Any)),
    ) : Array(Hash(String, ::DB::Any))
      union_keys = [] of String
      seen = Set(String).new
      rows.each do |row|
        row.each_key do |key|
          unless seen.includes?(key)
            seen << key
            union_keys << key
          end
        end
      end

      # Fast path: every row already has the same key set in the same
      # order — return as-is to avoid the allocation churn.
      already_uniform = rows.all? { |row| row.keys == union_keys }
      return rows if already_uniform

      fill_for_column = {} of String => ::DB::Any
      union_keys.each do |column|
        fill_for_column[column] = default_fill_for(model, column)
      end

      rows.map do |row|
        rebuilt = {} of String => ::DB::Any
        union_keys.each do |column|
          rebuilt[column] = row.has_key?(column) ? row[column] : fill_for_column[column]
        end
        rebuilt
      end
    end

    # H2 helper: resolve the per-column fill value for rows that omit a
    # column present in their siblings. We honour the field's configured
    # `default` (passed through `to_db` for type coercion) when the field
    # is non-nullable and has a non-nil default; otherwise nil, which the
    # DB will accept for nullable columns and reject (with a clear NOT
    # NULL message) for non-nullable ones — that's the correct surface
    # for the user, since a non-nullable column with no default that's
    # missing from a row is a real fixture-authoring bug.
    private def default_fill_for(model : Marten::DB::Model.class, column : String) : ::DB::Any
      field = model.fields.find { |fld| fld.db_column? && fld.db_column! == column }
      return unless field

      default_value = field.default
      return if default_value.nil?

      field.to_db(default_value)
    end

    private def with_constraints_disabled(&) : Nil
      case adapter_kind
      when :sqlite
        # SQLite's `PRAGMA foreign_keys` is a no-op inside an active
        # transaction (the docs are explicit about this), so we can't
        # toggle constraints from in here. Marten does not set
        # `PRAGMA foreign_keys = ON` for its SQLite connection either,
        # meaning FK constraints are not enforced at the DB level in the
        # current Marten/SQLite combination. The Loader's topological
        # sort is what actually keeps inserts FK-correct.
        yield
      when :postgres
        with_postgres_constraints_disabled { yield }
      else
        raise Error.new("MySQL not supported in v1; SQLite and Postgres only")
      end
    end

    # M2: `SET session_replication_role = 'replica'` requires superuser or
    # the `pg_write_server_files` role. Non-superuser developers get an
    # opaque `permission denied to set parameter` from Postgres before any
    # fixture row lands.
    #
    # Two opt-outs:
    #
    # 1. `MartenFixtures.configuration.disable_constraints = false` skips
    #    the SET entirely. The Loader's topological sort already produces
    #    FK-correct insertion order, so skipping is correct (just slower
    #    on tables with self-FKs or deferred-only constraints, where the
    #    DB-side constraint check still fires per row).
    #
    # 2. If the host doesn't opt out and the SET still fails, we catch
    #    `::DB::Error` and re-raise as `Error::ConstraintsDisableFailed`
    #    with a message that tells the developer their options. The
    #    underlying Postgres error is chained via `cause`.
    private def with_postgres_constraints_disabled(&) : Nil
      # MFR2: read `@config.disable_constraints?` (the loader's Configuration)
      # rather than the module-global. Pre-fix this consulted the global even
      # when a custom Configuration was passed to `Loader.new`, defeating the
      # documented per-loader override contract.
      unless @config.disable_constraints?
        yield
        return
      end

      begin
        issue_session_replication_role("replica")
      rescue ex : ::DB::Error
        raise Error::ConstraintsDisableFailed.new(
          "SET session_replication_role = 'replica' failed (Postgres reported: " \
          "#{ex.message}). This statement requires superuser or pg_write_server_files. " \
          "Either run fixtures as the migrations user, or disable the constraint-relax " \
          "step by setting `MartenFixtures.configuration.disable_constraints = false` — " \
          "the topological sort already produces FK-correct insert order, so disabling " \
          "is safe for the standard cross-model case.",
          cause: ex,
        )
      end

      begin
        yield
      ensure
        # MFR7: best-effort restore narrowed to `::DB::Error` only. The
        # transaction will roll back anyway on failure (we're inside
        # `connection.transaction`), so any session-scoped state changes
        # are discarded. We deliberately do NOT swallow non-DB errors
        # (e.g. programming bugs like `NilAssertionError` or a misuse
        # `KeyError`) — those should propagate so they're not masked by
        # a benign cleanup-time silence.
        begin
          issue_session_replication_role("origin")
        rescue ::DB::Error
          # Swallow — see above.
        end
      end
    end

    # MFR1: extracted as a protected method so spec subclasses can spy on
    # the call order / arguments (assert it fires exactly when
    # `disable_constraints?` is true, and never when it's false) without
    # needing a real Postgres connection. Production code path issues the
    # SET via `@connection.open(&.exec(...))` exactly as before.
    protected def issue_session_replication_role(value : String) : Nil
      @connection.open(&.exec("SET session_replication_role = '#{value}'"))
    end

    private def bump_sequences(models : Array(Marten::DB::Model.class)) : Nil
      models.each do |model|
        pk_field = model.fields.find(&.primary_key?)
        next unless pk_field
        next unless pk_field.db_column?
        bump_sequence(model.db_table, pk_field.db_column!)
      end
    end

    # M1: bump the Postgres sequence backing `table`'s `pk_column` so the
    # next application-level insert receives a PK strictly greater than the
    # highest value already in the table (the fixture-supplied PKs).
    #
    # Two correctness traps the previous single-line `setval(seq, GREATEST(MAX,1))`
    # call fell into:
    #
    # 1. `pg_get_serial_sequence($1, $2)` treats its first argument as a
    #    SQL identifier string. If the value isn't already quoted, Postgres
    #    parses + downcases it, so `"Users"` becomes `users` and the call
    #    raises `relation "users" does not exist`. We wrap the bound
    #    parameters in `quote_ident(...)` on the SQL side so any mixed-case
    #    `model.db_table` works. (Marten conventionally lowercases table
    #    names, so this is defence-in-depth.) The MAX subquery still has
    #    the identifier interpolated via `@connection.quote` because
    #    `MAX(t.<col>) FROM <table>` requires a literal identifier, not a
    #    runtime string — and `@connection.quote` is the same path Marten
    #    uses for every other generated identifier.
    #
    # 2. The two-arg `setval(seq, value)` form always marks the sequence as
    #    "called", so the *next* `nextval` returns `value + 1`. For an
    #    empty table that produces `id=2` on the first user-driven insert.
    #    The three-arg `setval(seq, value, is_called)` form takes a third
    #    boolean: `false` means "not yet called, next nextval returns
    #    value". We pass `max IS NOT NULL` so non-empty tables behave as
    #    before (next id = max+1) while empty tables get `is_called=false`
    #    and the next nextval returns 1 cleanly.
    private def bump_sequence(table : String, pk_column : String) : Nil
      sql = self.class.build_bump_sequence_sql(@connection, table, pk_column)
      @connection.open(&.scalar(sql, table, pk_column))
    end

    # Extracted so specs can assert on the emitted SQL shape without
    # exercising the Postgres-only execution path. The `table`/`pk_column`
    # bound-parameter values are also passed in (rather than just `$1`/`$2`
    # everywhere) because the inner MAX subquery needs them as literal
    # identifiers — but the `pg_get_serial_sequence` arguments stay as
    # `quote_ident($1)` / `quote_ident($2)` so an upstream caller can never
    # bypass the quoting by passing a pre-quoted string.
    # :nodoc:
    def self.build_bump_sequence_sql(
      connection : Marten::DB::Connection::Base,
      table : String,
      pk_column : String,
    ) : String
      table_qi = connection.quote(table)
      column_qi = connection.quote(pk_column)
      "SELECT setval(" \
      "pg_get_serial_sequence(quote_ident($1), quote_ident($2)), " \
      "GREATEST(COALESCE((SELECT MAX(#{column_qi}) FROM #{table_qi}), 0), 1), " \
      "(SELECT MAX(#{column_qi}) FROM #{table_qi}) IS NOT NULL" \
      ")"
    end

    # Protected (rather than private) so spec subclasses can stub the
    # adapter kind to exercise the unsupported-adapter error branch
    # without needing a real MySQL connection.
    protected def adapter_kind : Symbol
      case @connection
      when Marten::DB::Connection::SQLite     then :sqlite
      when Marten::DB::Connection::PostgreSQL then :postgres
      when Marten::DB::Connection::MySQL      then :mysql
      else                                         :unknown
      end
    end

    private def postgres? : Bool
      adapter_kind == :postgres
    end
  end
end
