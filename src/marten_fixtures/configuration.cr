module MartenFixtures
  # Top-level shard configuration. Mutated via `MartenFixtures.configure`.
  class Configuration
    VALID_TIMESTAMP_POLICIES = {:auto, :skip, :required}

    property fixtures_path : Path = Path["spec/fixtures"]
    getter timestamp_policy : Symbol = :auto
    property evaluator : MartenFixtures::Evaluator?

    # M2: when true (the default), the Postgres `Inserter` issues
    # `SET session_replication_role = 'replica'` for the duration of the
    # transaction, which suppresses FK + trigger enforcement on inserts.
    # That statement requires superuser or the `pg_write_server_files`
    # role; flip this to `false` if your fixtures-loading DB user lacks
    # those privileges. The Loader's topological sort already produces
    # FK-correct insert order, so disabling is safe for the standard
    # cross-model case (self-FKs or deferred-only constraints aside).
    # On SQLite this flag has no effect — the equivalent
    # `PRAGMA foreign_keys` is a no-op inside an active transaction.
    property? disable_constraints : Bool = true

    def fixtures_path=(value : String | Path)
      @fixtures_path = value.is_a?(Path) ? value : Path[value]
    end

    def timestamp_policy=(value : Symbol)
      unless VALID_TIMESTAMP_POLICIES.includes?(value)
        raise ArgumentError.new(
          "Invalid timestamp_policy #{value.inspect}; expected one of #{VALID_TIMESTAMP_POLICIES}"
        )
      end
      @timestamp_policy = value
    end
  end
end
