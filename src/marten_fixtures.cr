require "marten"
require "crinja"
require "./marten_fixtures/error"
require "./marten_fixtures/label"
require "./marten_fixtures/label_registry"
require "./marten_fixtures/helper_registry"
require "./marten_fixtures/evaluator"
require "./marten_fixtures/configuration"
require "./marten_fixtures/fixture_file"
require "./marten_fixtures/polymorphic_resolver"
require "./marten_fixtures/row_interpolator"
require "./marten_fixtures/inserter"
require "./marten_fixtures/loader"
require "./marten_fixtures/accessors"

module MartenFixtures
  VERSION = "0.1.0"

  @@configuration = Configuration.new

  # Most recently populated label registry. Set by `Loader#load`; consulted by
  # `Accessors#fixture` so that rows with explicit `id:` values are resolvable
  # by label (H1 / L12). `nil` until the first load completes.
  @@last_label_registry : LabelRegistry? = nil

  def self.configure(&) : Nil
    yield @@configuration
  end

  def self.configuration : Configuration
    @@configuration
  end

  # :nodoc:
  def self.last_label_registry : LabelRegistry?
    @@last_label_registry
  end

  # :nodoc:
  def self.last_label_registry=(registry : LabelRegistry?)
    @@last_label_registry = registry
  end

  def self.identify(label : String) : Int64
    Label.identify(label)
  end

  # Loads every `*.yml` file under the configured (or supplied) fixtures
  # directory, ordered by filesystem-glob order.
  def self.load_all(dir : String | Path? = nil) : Nil
    dir_path = Path[dir || @@configuration.fixtures_path]
    files = Dir.glob(dir_path.join("**/*.yml").to_s).sort.map { |file| Path[file] }
    load_files(files)
  end

  # Loads the supplied fixture files in caller-supplied order.
  def self.load(*paths : String | Path) : Nil
    load_files(paths.to_a.map { |path| Path[path] })
  end

  private def self.load_files(files : Array(Path)) : Nil
    Loader.new(files, @@configuration, HelperRegistry.global).load
  end
end
