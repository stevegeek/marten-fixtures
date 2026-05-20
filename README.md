# marten_fixtures

Rails-style YAML fixtures for [Marten](https://martenframework.com).

`marten_fixtures` ports `ActiveRecord::FixtureSet` to Crystal/Marten: per-file
YAML fixtures, label references that resolve to deterministic primary keys
(CRC32 of the label — byte-compatible with Rails), foreign-key auto-resolution,
polymorphic shorthand, and ERB-equivalent templating via
[Crinja](https://github.com/straight-shoota/crinja).

## Installation

Add to `shard.yml`:

```yaml
dependencies:
  marten_fixtures:
    github: stevegeek/marten-fixtures
```

Then `shards install`.

## Quick start

```crystal
# spec/spec_helper.cr
require "spec"
require "marten/spec"
require "marten_fixtures"

Spec.before_each do
  Marten::Spec.flush_databases
  MartenFixtures.load_all("spec/fixtures")
end
```

```crystal
# spec/access_spec.cr
describe "Access" do
  include MartenFixtures::Accessors

  it "links david to handbook" do
    access = Access.get!(user: fixture(User, :david), book: fixture(Book, :handbook))
    access.level.should eq("editor")
  end
end
```

The fixture files themselves are plain YAML — label-keyed top-level mappings,
one file per table:

```yaml
# spec/fixtures/users.yml
david:
  name: David
  email: david@example.com
  account: engineering           # FK label → resolved to account_id

alice:
  name: Alice
  email: alice@example.com
  account: marketing
```

The file's stem (`users`) is matched against `Marten::DB::Model.db_table`;
subdirectories under `fixtures/` are flattened into the table name
(`fixtures/admin/users.yml` → `admin_users`).

## Public API

| Method | Purpose |
|---|---|
| `MartenFixtures.load_all(dir)` | Glob `**/*.yml` under `dir` (defaults to `configuration.fixtures_path`) and load every file. |
| `MartenFixtures.load(path, …)` | Load specific files in the caller-supplied order. |
| `MartenFixtures.identify(label)` | Return the `Int64` primary key the loader will assign to `label`. |
| `MartenFixtures.configure { |c| … }` | Set `fixtures_path`, `timestamp_policy`, custom `evaluator`. |
| `MartenFixtures.register_helper(name) { |args, ctx| … }` | Expose a Crinja-callable helper to all fixture templates. |
| `include MartenFixtures::Accessors` → `fixture(Model, label)` | Spec-side sugar: returns the loaded row by label. Accepts `String` or `Symbol`. |

## Fixture file syntax

### Plain YAML

The default case — no template syntax, no helpers — is just a YAML mapping of
labels to attribute hashes:

```yaml
engineering:
  name: Engineering
  plan: enterprise
```

### Foreign keys by label

A `ManyToOne` / `OneToOne` field accepts the *label* of a row in the related
table (the loader looks up the pk in the global registry):

```yaml
david:
  name: David
  account: engineering   # accounts.yml's "engineering" row
```

The `account:` key is rewritten to `account_id` and populated with
`MartenFixtures.identify("engineering")`.

### Polymorphic shorthand

For `polymorphic` fields, the value is `"label (Type)"`. The short type name
is matched against the field's compile-time `to:` list (exact match or
`::ShortName` suffix), and the loader emits both the `_type` and `_id`
columns:

```yaml
# leaves.yml
lead_welcome:
  position: 1
  leafable: welcome (Post)       # → leafable_type="Post", leafable_id=identify("welcome")
```

### Crinja templating

Any `{{ … }}` expression or `{% … %}` statement triggers a Crinja render pass
before YAML parsing. Bracketed syntax differs from ERB but the structure maps
1:1 — see [MIGRATION.md](MIGRATION.md).

```yaml
david:
  name: David
  email: david@example.com
  password_digest: {{ bcrypt("password123") }}
```

Helpers registered via `MartenFixtures.register_helper` are exposed as Crinja
functions inside templates.

## CRC32 label IDs

`MartenFixtures.identify(label)` returns
`Digest::CRC32.checksum(label).to_i64 % (2**30 - 1)` — the same value Ruby's
`Zlib.crc32(label) % (2**30 - 1)` produces. Rails' `ActiveRecord::FixtureSet`
uses the identical formula, so a fixture labelled `david` resolves to the same
`id` in both Rails and Marten test suites. This makes it safe to port a Rails
fixture file straight across: cross-fixture references and any hand-written
foreign-key assertions still line up.

UUID primary keys are derived via `UUID.v5` using the RFC 4122 DNS namespace
(`6ba7b810-9dad-11d1-80b4-00c04fd430c8`) — again matching the Rails default.

## Postgres setup

Postgres is a first-class target. The `Inserter` toggles
`session_replication_role` to disable FK checks during the bulk load and runs
`SELECT setval(pg_get_serial_sequence(…), MAX(id))` for every table touched,
so app-allocated ids do not collide with sequence-allocated ones after the
fixtures land.

To run the test suite against Postgres, add `pg` to your dev-dependencies and
start a local Postgres instance, then:

```sh
PG_DB=marten_fixtures_test MARTEN_FIXTURES_BACKEND=postgres script/cr spec
```

The spec suite reads the backend choice from `MARTEN_FIXTURES_BACKEND` (default
`sqlite`); `PG_HOST`, `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASSWORD` override the
connection settings. The sequence-bump example in `inserter_spec.cr` is marked
`pending` on SQLite and runs only when the Postgres backend is active.

For your own app, just declare the database as usual in `config/settings/test.cr`:

```crystal
config.database do |db|
  db.backend = :postgresql
  db.host = "localhost"
  db.name = "myapp_test"
  db.user = ENV["USER"]
end
```

The loader picks up the active connection via `Marten::DB::Connection.default`.

## Helpers (companion shards)

Companion shards can expose richer per-row computation by registering named
helpers at require time. A helper receives the raw kwargs (as
`Hash(String, YAML::Any)`) and a `MartenFixtures::EvalContext` carrying the
fixtures-path root and the live label registry:

```crystal
# marten-storages
MartenFixtures.register_helper("blob") do |args, ctx|
  filename = args["filename"].as_s
  {
    "key"          => Digest::SHA256.hexdigest(filename),
    "byte_size"    => File.size(ctx.fixtures_path / "files" / filename).to_s,
    "content_type" => args["content_type"]?.try(&.as_s) || "application/octet-stream",
  }
end
```

The returned `Hash(String, String)` can be merged into a fixture row by the
companion shard's own machinery (e.g. a dedicated YAML pre-processor). See
"Known limitations" below for the v0.2 return-type plan.

## Known limitations / v0.2 candidates

- **Helper return type.** Helpers currently return
  `Hash(String, String)` for row-expansion use cases. Calling a helper
  *inside* a Crinja `{{ … }}` expression needs the return value to be
  stringifiable — Crinja will not happily render a `Hash`. The v0.2 plan is
  to split the API into `register_row_helper` (Hash return, expanded into
  the row) and `register_template_helper` (String return, callable inline),
  or to widen the proc signature to allow either.
- **No HABTM / `many_to_many` join-table fixtures.** Marten's
  `many_to_many` doesn't surface its join table as a first-class model;
  shipping a `_join.yml` convention would mean a non-trivial extension that
  the Writebook port (the driving use case) doesn't need yet.
- **No STI `type:` column translation.** Marten's polymorphic field is the
  delegated-type equivalent; STI is not a Marten pattern, so no fixture
  syntax exists for it.
- **No bundled transactional-fixtures lifecycle.** `Marten::Spec.flush_databases`
  in a `before_each` works; a properly bundled "load once, rollback per test"
  helper is deferred until the Writebook port exercises it.
- **MySQL is not supported.** SQLite and Postgres only. Adding MySQL would
  mainly mean a third FK-disable branch in `Inserter` plus a sequence-bump
  equivalent (`AUTO_INCREMENT` reset).

## Development

```sh
shards install
script/cr spec/   # or `crystal spec`
```

To lint with ameba (the shard does not declare ameba as a dev-dep — borrow it
from a sibling shard that does):

```sh
cd ../marten-turbo && \
  crystal lib/ameba/bin/ameba.cr \
    --config ../marten-fixtures/.ameba.yml \
    ../marten-fixtures/src/ ../marten-fixtures/spec/
```

## License

MIT — see [LICENSE](LICENSE).
