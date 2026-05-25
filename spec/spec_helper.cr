ENV["MARTEN_ENV"] = "test"

require "spec"
require "file_utils"
require "sqlite3"
{% if env("MARTEN_FIXTURES_BACKEND") == "postgres" %}
  require "pg"
{% end %}
require "../src/marten_fixtures"
require "marten/spec"

require "./test_project/app"
require "./test_project/models/**"

BACKEND = ENV.fetch("MARTEN_FIXTURES_BACKEND", "sqlite")

Marten.configure :test do |config|
  config.secret_key = "__insecure_spec_secret_#{Random::Secure.random_bytes(16).hexstring}__"
  config.log_level = ::Log::Severity::None

  config.installed_apps = [MartenFixturesSpecApp]

  config.database do |db|
    case BACKEND
    when "postgres"
      db.backend = :postgresql
      db.host = ENV["PG_HOST"]? || "localhost"
      db.port = (ENV["PG_PORT"]? || "5432").to_i
      db.name = ENV["PG_DB"]? || "marten_fixtures_test"
      db.user = ENV["PG_USER"]? || ENV["USER"]? || "postgres"
      db.password = ENV["PG_PASSWORD"]? || ""
    else
      db.backend = :sqlite
      db.name = ":memory:"
    end
  end
end

Spec.before_each do
  MartenFixtures.configure do |c|
    c.fixtures_path = Path["spec/fixtures"]
    c.timestamp_policy = :auto
    c.evaluator = nil
    c.disable_constraints = true
  end
  MartenFixtures::HelperRegistry.reset_global!
  # MFR6: clear the cross-test-leakable `@@last_label_registry` so a spec
  # that asserts `MartenFixtures.last_label_registry.nil?` (or that needs
  # a clean baseline before its own `load`) is not poisoned by the
  # previous example's load.
  MartenFixtures.last_label_registry = nil
end
