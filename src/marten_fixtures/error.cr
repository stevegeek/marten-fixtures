module MartenFixtures
  class Error < Exception
    class UnknownTable < Error; end

    class UnknownLabel < Error; end

    class UnknownPolymorphicType < Error; end

    class UnknownField < Error; end

    class UnsupportedPK < Error; end

    class TemplateUnsupported < Error; end

    # L1: raised when the same `(model_class, label)` key is registered
    # twice with *different* primary-key values. Cross-file collisions
    # (two YAML files contributing to the same model, same label, but
    # different explicit `id:` values) used to silently corrupt the
    # label registry; we now raise loudly so the bug surfaces at load
    # time instead of at FK-resolution time. Re-registering the same
    # `(model_class, label)` key with the *same* PK value is idempotent
    # (no-op) — that case is harmless and would only spuriously fail
    # callers that legitimately replay a partial load.
    class DuplicateLabel < Error; end

    # Raised when the Postgres `SET session_replication_role = 'replica'`
    # statement fails (typically because the connecting role lacks
    # superuser / `pg_write_server_files`). The error message lists the
    # available workarounds (run as a superuser, or set
    # `MartenFixtures.configuration.disable_constraints = false`).
    class ConstraintsDisableFailed < Error; end

    # Raised when a Crinja helper returns a value whose Crystal type is not
    # in `CrinjaEvaluator#to_yaml_any`'s recognised set. Loud-fail is
    # preferred over silent `.to_s` flattening because the v0.2 plan is to
    # widen the helper return type (see README), and the silent path makes
    # a regression invisible until a string column quietly absorbs garbage.
    class UnsupportedHelperReturnType < Error; end
  end
end
