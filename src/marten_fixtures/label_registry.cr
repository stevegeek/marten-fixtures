module MartenFixtures
  # Process-wide map of fixture label → assigned primary key, keyed by
  # `"FullyQualifiedModelName/label"`. Populated during the loader's first
  # pass; read during FK / polymorphic expansion in the second pass.
  class LabelRegistry
    include Enumerable({String, Int64 | String})

    def initialize
      @store = {} of String => Int64 | String
    end

    def register(model_class : Marten::DB::Model.class, label : String, pk : Int64 | String) : Nil
      @store[key_for(model_class, label)] = pk
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
