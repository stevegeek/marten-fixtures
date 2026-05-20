module MartenFixtures
  # One YAML fixture file on disk, resolved against a list of candidate
  # Marten models. Pure data: parsing happens elsewhere.
  struct FixtureFile
    getter path : Path
    getter table_name : String
    getter model_class : Marten::DB::Model.class

    def initialize(@path : Path, models : Enumerable(Marten::DB::Model.class))
      @table_name = derive_table_name(@path)
      @model_class = resolve_model_class(@table_name, models)
    end

    private def derive_table_name(path : Path) : String
      stem = path.stem.downcase
      parents = path.parts[0...-1].map(&.downcase)
      anchor = parents.index("fixtures")
      prefix = anchor ? parents[(anchor + 1)..] : [] of String
      (prefix + [stem]).reject(&.empty?).join("_")
    end

    private def resolve_model_class(
      table_name : String,
      models : Enumerable(Marten::DB::Model.class),
    ) : Marten::DB::Model.class
      match = models.find { |model| model.db_table == table_name }
      return match if match

      known = models.map(&.db_table).join(", ")
      raise Error::UnknownTable.new(
        "No model found for fixture file #{path} (table=#{table_name.inspect}); " \
        "known tables: #{known}"
      )
    end
  end
end
