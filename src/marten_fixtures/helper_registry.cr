require "yaml"
require "./label_registry"

module MartenFixtures
  # Context handed to a helper Proc when invoked from a fixture template.
  # Carries everything a companion shard might need to compute file-system
  # paths or resolve cross-fixture references without holding a reference
  # to the Loader itself.
  struct EvalContext
    getter fixtures_path : Path
    getter label_registry : LabelRegistry

    def initialize(@fixtures_path : Path, @label_registry : LabelRegistry)
    end
  end

  alias HelperProc = Proc(Hash(String, YAML::Any), EvalContext, Hash(String, String))

  # Registry of named helpers exposed to fixture templates. Companion
  # shards (`marten-storages`, `marten-text`) call `register` at require
  # time; the evaluator then surfaces each registered name as a callable
  # function inside Crinja templates.
  class HelperRegistry
    include Enumerable({String, HelperProc})

    @@global : HelperRegistry?

    # Process-wide singleton used by the top-level `MartenFixtures.register_helper`.
    def self.global : HelperRegistry
      @@global ||= new
    end

    # Drops the process-wide singleton so the next `global` call returns
    # a fresh registry. Intended for test-suite `before_each` hooks.
    def self.reset_global! : Nil
      @@global = nil
    end

    def initialize
      @helpers = {} of String => HelperProc
    end

    def register(name : String, &block : HelperProc) : Nil
      @helpers[name] = block
    end

    def fetch(name : String) : HelperProc?
      @helpers[name]?
    end

    def each(& : {String, HelperProc} ->) : Nil
      @helpers.each { |k, v| yield({k, v}) }
    end

    def size : Int32
      @helpers.size
    end
  end

  # Top-level entry point: register a helper on the global registry.
  # Companion shards use this at require time.
  def self.register_helper(name : String, &block : HelperProc) : Nil
    HelperRegistry.global.register(name, &block)
  end
end
