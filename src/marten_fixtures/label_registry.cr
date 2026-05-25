module MartenFixtures
  # Process-wide map of fixture label → assigned primary key, keyed by
  # `"FullyQualifiedModelName/label"`. Populated during the loader's first
  # pass; read during FK / polymorphic expansion in the second pass.
  class LabelRegistry
    include Enumerable({String, Int64 | String})

    def initialize
      @store = {} of String => Int64 | String
    end

    # L1: within-file last-write-wins is fine (the loader's pass-1 only
    # visits each row once anyway). Cross-file collisions — two YAML
    # files contributing to the same model with the same label but
    # *different* PKs — used to silently overwrite; we now raise
    # `Error::DuplicateLabel` so the bug surfaces at load time. Same
    # `(model_class, label)` key registered with the *same* PK value
    # is idempotent (no-op).
    def register(model_class : Marten::DB::Model.class, label : String, pk : Int64 | String) : Nil
      key = key_for(model_class, label)
      if existing = @store[key]?
        return if existing == pk
        raise Error::DuplicateLabel.new(
          "Duplicate fixture label #{model_class.name}/#{label}: already registered with " \
          "pk=#{existing.inspect}, refusing to overwrite with pk=#{pk.inspect}. Two YAML " \
          "files (or two rows in the same file targeting the same explicit `id:`) are " \
          "competing for this label — rename one or align the explicit `id:` values."
        )
      end
      @store[key] = pk
    end

    def lookup(model_class : Marten::DB::Model.class, label : String) : Int64 | String
      lookup?(model_class, label) || raise Error::UnknownLabel.new(
        "No fixture registered for #{model_class.name}/#{label}"
      )
    end

    def lookup?(model_class : Marten::DB::Model.class, label : String) : (Int64 | String)?
      @store[key_for(model_class, label)]?
    end

    def each(& : {String, Int64 | String} ->) : Nil
      @store.each { |k, v| yield({k, v}) }
    end

    def size : Int32
      @store.size
    end

    private def key_for(model_class : Marten::DB::Model.class, label : String) : String
      "#{model_class.name}/#{label}"
    end
  end
end
