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
    BATCH_SIZE = 500

    def initialize(@connection : Marten::DB::Connection::Base)
    end

    def insert_all(rows_by_model : Hash(Marten::DB::Model.class, Array(Hash(String, ::DB::Any)))) : Nil
      @connection.transaction do
        with_constraints_disabled do
          rows_by_model.each do |model, rows|
            insert_for_model(model, rows)
          end
          bump_sequences(rows_by_model.keys) if postgres?
        end
      end
    end

    private def insert_for_model(model : Marten::DB::Model.class, rows : Array(Hash(String, ::DB::Any))) : Nil
      return if rows.empty?
      columns = rows.first.size
      batch_size = [@connection.bulk_batch_size(rows.size, columns), BATCH_SIZE].min
      rows.each_slice(batch_size) do |slice|
        @connection.bulk_insert(model.db_table, slice)
      end
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
        @connection.open(&.exec("SET session_replication_role = 'replica'"))
        begin
          yield
        ensure
          @connection.open(&.exec("SET session_replication_role = 'origin'"))
        end
      else
        raise Error.new("MySQL not supported in v1; SQLite and Postgres only")
      end
    end

    private def bump_sequences(models : Array(Marten::DB::Model.class)) : Nil
      models.each do |model|
        pk_field = model.fields.find(&.primary_key?)
        next unless pk_field
        next unless pk_field.db_column?
        bump_sequence(model.db_table, pk_field.db_column!)
      end
    end

    private def bump_sequence(table : String, pk_column : String) : Nil
      table_qi = @connection.quote(table)
      column_qi = @connection.quote(pk_column)
      sql = "SELECT setval(" \
            "pg_get_serial_sequence($1, $2), " \
            "GREATEST(COALESCE((SELECT MAX(#{column_qi}) FROM #{table_qi}), 0), 1)" \
            ")"
      @connection.open(&.scalar(sql, table, pk_column))
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
