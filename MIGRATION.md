# Migrating Rails fixtures to marten_fixtures

This is the short reference for porting an existing `test/fixtures/*.yml`
corpus from a Rails project to a Marten project using `marten_fixtures`.
The data model carries over almost verbatim — the only mechanical rewrite
needed is the ERB → Crinja syntax change.

## Syntax mapping

| Rails idiom | marten_fixtures equivalent |
|---|---|
| `<%= 1 + 1 %>` (ERB expression) | `{{ 1 + 1 }}` (Crinja expression) |
| `<% x = compute %>` (ERB statement) | `{% set x = compute() %}` (Crinja statement) |
| `<% require "digest" %>` | not supported — write a Crystal helper and register it via `MartenFixtures.register_helper`. |
| `owner: kevin (User)` polymorphic shorthand | same syntax (preserved). Short type matches the field's `to:` list; namespaced models resolve by `::ShortName` suffix. |
| `id: 12345` explicit primary key | not needed — `MartenFixtures.identify(label)` (CRC32 of label) is identical to Rails' default. Drop `id:` lines, or keep them and they will be honoured as overrides. |
| `_fixture_accessors` typed methods (`users(:david)`) | `include MartenFixtures::Accessors` and call `fixture(User, :david)`. |
| `fixture_file_upload(...)` | register a helper that returns the desired column hash, or compute the file metadata in Crystal and reference it via `{{ … }}`. |
| `fixture_file "partial.yml"` ERB partial include | not supported — inline the partial or refactor to a registered helper. |
| `ERB.new(...).result(binding)` in a custom loader | replace with a custom `MartenFixtures::Evaluator` set via `MartenFixtures.configure`. |
| `set_fixture_class` filename → class override | not supported in v1 — name the file to match `Model.db_table`. |

## Primary-key compatibility

Rails and `marten_fixtures` use the same CRC32-based label → id formula:

```ruby
# Rails
ActiveRecord::FixtureSet.identify("david")  # => 207281424
```

```crystal
# Marten
MartenFixtures.identify("david")            # => 207281424_i64
```

This means a partially-ported codebase can share fixture data between Ruby
and Crystal test suites without re-keying anything. UUID primary keys also
match (both use `UUID.v5` with the RFC 4122 DNS namespace).

## What is NOT supported

Brief — see the "Known limitations" section of [README.md](README.md) for the
fuller list. In short: HABTM join-table fixtures, STI `type:` column
translation, multi-database `db:` overrides, ERB-shim preprocessing, and a
bundled transactional-fixtures lifecycle are all v0.2-or-later territory. The
Writebook port works fine without them; if your project needs one, open an
issue against the shard.

## Typical migration steps

1. `cp -r test/fixtures spec/fixtures` from the Rails project.
2. Rewrite ERB tags: `<%= … %>` → `{{ … }}`, `<% … %>` → `{% … %}`.
3. Replace any ERB `require` / partial-include / `fixture_file_upload` with a
   `MartenFixtures.register_helper` block or a precomputed value.
4. In `spec/spec_helper.cr`, add
   `Spec.before_each { Marten::Spec.flush_databases; MartenFixtures.load_all("spec/fixtures") }`.
5. Replace each `users(:david)` accessor in a spec with `fixture(User, :david)`
   after `include MartenFixtures::Accessors` in the surrounding `describe`.
