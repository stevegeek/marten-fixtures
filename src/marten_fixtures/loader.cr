require "yaml"

module MartenFixtures
  # Orchestrates the two-pass fixture load.
  #
  # Pass 1 walks every file, derives the target model from the file path,
  # parses the YAML, and registers a deterministic CRC32-derived PK for
  # each label in the `LabelRegistry`. Pass 1 does NOT render templates —
  # the top-level row labels (the only keys read in pass 1) are static.
  #
  # Pass 2 renders each file through the template evaluator (so helpers
  # like `bcrypt(...)` fire), parses the rendered YAML, interpolates each
  # row through `RowInterpolator`, and bulk-inserts everything inside a
  # single transaction via `Inserter`.
  class Loader
    private alias ParsedFile = NamedTuple(
      file: FixtureFile,
      raw: String,
      rows: Hash(String, Hash(String, YAML::Any)),
    )

    @models : Array(Marten::DB::Model.class)
    @expanded_file_dirs : Array(Path)
    @expanded_configured_path : Path

    def initialize(
      @files : Array(Path),
      @config : Configuration = MartenFixtures.configuration,
      @helper_registry : HelperRegistry = HelperRegistry.global,
    )
      @label_registry = LabelRegistry.new
      @parsed = [] of ParsedFile
      @models = collect_models
      # Resolve every path against the *current* working directory once at
      # construction time. `Path#expand` consults `Dir.current`, so doing
      # this lazily would attribute paths to whatever CWD happens to be
      # live when the evaluator is first built (parallel test runners,
      # programs that `Dir.cd`, etc.).
      @expanded_configured_path = @config.fixtures_path.expand
      @expanded_file_dirs = @files.map(&.parent.expand)
      @expanded_file_dirs.uniq!
    end

    getter label_registry : LabelRegistry

    def load : Nil
      pass_one_register_labels
      pass_two_interpolate_and_insert
    end

    private def pass_one_register_labels : Nil
      @files.each do |path|
        raw = File.read(path)
        rows = parse_rows(raw, path)
        fixture_file = FixtureFile.new(path, @models)
        pk_field = fixture_file.model_class.fields.find!(&.primary_key?)

        rows.each_key do |label|
          pk = Label.identify(label, pk_field)
          @label_registry.register(fixture_file.model_class, label, pk)
        end

        @parsed << {file: fixture_file, raw: raw, rows: rows}
      end
    end

    private def pass_two_interpolate_and_insert : Nil
      rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
      evaluator = evaluator_for(@label_registry)

      @parsed.each do |entry|
        rendered_rows = render_rows(evaluator, entry)
        interpolator = RowInterpolator.new(
          entry[:file].model_class,
          @label_registry,
          @config.timestamp_policy,
        )

        rendered_rows.each do |label, raw_attrs|
          row = interpolator.interpolate(label, raw_attrs)
          rows_by_model[entry[:file].model_class] ||= [] of Hash(String, ::DB::Any)
          rows_by_model[entry[:file].model_class] << row
        end
      end

      return if rows_by_model.empty?

      ordered = topo_sort_models(rows_by_model.keys)
      sorted_rows = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
      ordered.each { |model| sorted_rows[model] = rows_by_model[model] }

      connection = Marten::DB::Connection.default
      Inserter.new(connection).insert_all(sorted_rows)
    end

    # Test-only hook to invoke the private topological sort with a
    # synthesised dependency graph (so cycles and two-FK-to-same-parent
    # scenarios can be exercised without adding production models).
    # `extra_edges` lets a spec inject `model -> dep` edges that aren't
    # present in the real `deps_for` output.
    #
    # :nodoc:
    def topo_sort_for_spec(
      models : Array(Marten::DB::Model.class),
      extra_edges : Hash(Marten::DB::Model.class, Array(Marten::DB::Model.class)) = {} of Marten::DB::Model.class => Array(Marten::DB::Model.class),
    ) : Array(Marten::DB::Model.class)
      @spec_extra_edges = extra_edges
      result = topo_sort_models(models)
      result
    ensure
      @spec_extra_edges = nil
    end

    @spec_extra_edges : Hash(Marten::DB::Model.class, Array(Marten::DB::Model.class))? = nil

    # Topologically sorts the given models so that any model with a
    # ManyToOne/OneToOne/Polymorphic dependency on another model in the
    # set is inserted *after* its dependencies. Uses Kahn's algorithm.
    # Raises `Error` if the dependency graph contains a cycle; the error
    # message includes the actual cycle path (e.g. "A -> B -> C -> A")
    # rather than just the set of unsorted models.
    #
    # NOTE: self-referential FKs (e.g. `manager :many_to_one, to: Employee`)
    # are skipped — they do not affect cross-model ordering, but they DO
    # mean parent rows must precede child rows *within* the same model's
    # fixture YAML. Row-level ordering is the user's responsibility.
    private def topo_sort_models(
      models : Array(Marten::DB::Model.class),
    ) : Array(Marten::DB::Model.class)
      model_set = models.to_set
      dependencies = {} of Marten::DB::Model.class => Set(Marten::DB::Model.class)
      # `dependents` uses Set, not Array — a model with two FKs to the
      # same parent (e.g. `created_by`, `updated_by` → User) must NOT
      # appear twice in `dependents[User]`, or Kahn's inner loop will
      # double-decrement and double-enqueue, producing a spurious cycle
      # error.
      dependents = {} of Marten::DB::Model.class => Set(Marten::DB::Model.class)

      models.each do |model|
        dependencies[model] = Set(Marten::DB::Model.class).new
        dependents[model] = Set(Marten::DB::Model.class).new
      end

      models.each do |model|
        deps_for(model).each do |dep|
          # Only track dependencies within the current load set; FKs to
          # models not being loaded here are externally satisfied.
          next unless model_set.includes?(dep)
          next if dep == model
          dependencies[model] << dep
          dependents[dep] << model
        end
      end

      # Kahn: start with models that have no in-set dependencies.
      ready = models.select { |model| dependencies[model].empty? }
      ordered = [] of Marten::DB::Model.class

      until ready.empty?
        model = ready.shift
        ordered << model
        dependents[model].each do |dependent|
          dependencies[dependent].delete(model)
          ready << dependent if dependencies[dependent].empty?
        end
      end

      if ordered.size != models.size
        raise Error.new(cycle_error_message(models, ordered, dependencies))
      end

      ordered
    end

    # Builds an actionable error message when Kahn's algorithm fails to
    # consume the entire graph. Walks the surviving dependency edges with
    # DFS to find an actual cycle path; reports it edge-by-edge so the
    # user can see which FK closes the loop.
    private def cycle_error_message(
      models : Array(Marten::DB::Model.class),
      ordered : Array(Marten::DB::Model.class),
      dependencies : Hash(Marten::DB::Model.class, Set(Marten::DB::Model.class)),
    ) : String
      remaining = models - ordered
      cycle = find_cycle(remaining, dependencies)
      remaining_names = remaining.map(&.name).join(", ")
      if cycle && cycle.size >= 2
        path = cycle.map(&.name).join(" -> ")
        suffix = remaining.size > cycle.size ? " (other cycles may also be present among #{remaining_names})" : ""
        "Fixture model dependency cycle: #{path}#{suffix}"
      else
        "Fixture model dependency cycle among: #{remaining_names}"
      end
    end

    # DFS from each remaining node to find a cycle path. Returns an array
    # of models forming the cycle (with the start node repeated at the
    # end, e.g. `[A, B, C, A]`) or nil if no cycle is found.
    private def find_cycle(
      remaining : Array(Marten::DB::Model.class),
      dependencies : Hash(Marten::DB::Model.class, Set(Marten::DB::Model.class)),
    ) : Array(Marten::DB::Model.class)?
      remaining.each do |start|
        path = [] of Marten::DB::Model.class
        on_stack = Set(Marten::DB::Model.class).new
        result = dfs_for_cycle(start, dependencies, path, on_stack, remaining.to_set)
        return result if result
      end
      nil
    end

    private def dfs_for_cycle(
      node : Marten::DB::Model.class,
      dependencies : Hash(Marten::DB::Model.class, Set(Marten::DB::Model.class)),
      path : Array(Marten::DB::Model.class),
      on_stack : Set(Marten::DB::Model.class),
      restrict_to : Set(Marten::DB::Model.class),
    ) : Array(Marten::DB::Model.class)?
      path << node
      on_stack << node

      dependencies[node].each do |dep|
        next unless restrict_to.includes?(dep)
        if on_stack.includes?(dep)
          start_index = path.index!(dep)
          return path[start_index..] + [dep]
        end
        next if path.includes?(dep)
        result = dfs_for_cycle(dep, dependencies, path, on_stack, restrict_to)
        return result if result
      end

      on_stack.delete(node)
      path.pop
      nil
    end

    private def deps_for(model : Marten::DB::Model.class) : Array(Marten::DB::Model.class)
      deps = [] of Marten::DB::Model.class
      model.fields.each do |field|
        case field
        when Marten::DB::Field::ManyToOne, Marten::DB::Field::OneToOne
          deps << field.related_model
        when Marten::DB::Field::Polymorphic
          PolymorphicResolver.target_models(field).each { |target| deps << target }
        end
      end
      if extra = @spec_extra_edges
        extra[model]?.try(&.each { |dep| deps << dep })
      end
      deps
    end

    private def render_rows(
      evaluator : Evaluator,
      entry : ParsedFile,
    ) : Hash(String, Hash(String, YAML::Any))
      return entry[:rows] if evaluator.is_a?(PlainEvaluator) && !template_syntax?(entry[:raw])

      rendered_source = evaluator.evaluate(entry[:raw], {} of String => String)
      parse_rows(rendered_source, entry[:file].path)
    end

    private def parse_rows(source : String, path : Path) : Hash(String, Hash(String, YAML::Any))
      parsed = YAML.parse(source)
      raw = parsed.raw
      return {} of String => Hash(String, YAML::Any) if raw.nil?

      unless raw.is_a?(Hash)
        raise Error.new("Fixture file #{path} must contain a YAML mapping at the top level")
      end

      rows = {} of String => Hash(String, YAML::Any)
      raw.each do |key, value|
        label = key.as_s
        attrs_raw = value.raw
        unless attrs_raw.is_a?(Hash)
          raise Error.new(
            "Fixture row #{label.inspect} in #{path} must be a YAML mapping of attributes"
          )
        end

        attrs = {} of String => YAML::Any
        attrs_raw.each { |k, v| attrs[k.as_s] = v }
        rows[label] = attrs
      end
      rows
    end

    private def evaluator_for(label_registry : LabelRegistry) : Evaluator
      if existing = @config.evaluator
        return existing
      end

      eval_context = EvalContext.new(eval_context_path, label_registry)
      CrinjaEvaluator.new(helper_registry: @helper_registry, eval_context: eval_context)
    end

    # The `fixtures_path` exposed to helpers should reflect the files
    # actually being loaded, not the configured default.
    #
    # All path expansion happens at `Loader` construction time (so CWD
    # changes after `Loader.new` do not corrupt the result).
    #
    # - Single directory → return it.
    # - All dirs nested under the configured root → return the configured
    #   root (the typical `load_all` case where a nested subdir is just
    #   part of the fixtures tree).
    # - Otherwise → return the least-common-ancestor of the loaded file
    #   directories, and emit a STDERR warning that the files span dirs
    #   outside the configured root.
    private def eval_context_path : Path
      return @expanded_configured_path if @expanded_file_dirs.empty?
      return @expanded_file_dirs.first if @expanded_file_dirs.size == 1

      configured_str = @expanded_configured_path.to_s
      under_configured = @expanded_file_dirs.all?(&.to_s.starts_with?(configured_str))
      return @expanded_configured_path if under_configured

      lca = least_common_ancestor(@expanded_file_dirs)
      STDERR.puts(
        "[marten-fixtures] warning: loaded files span multiple directories " \
        "(#{@expanded_file_dirs.map(&.to_s).join(", ")}); EvalContext.fixtures_path " \
        "falls back to least-common-ancestor #{lca}"
      )
      lca
    end

    # Returns the deepest path that is a prefix of every input path.
    # Inputs are expected to be already-expanded absolute paths.
    private def least_common_ancestor(paths : Array(Path)) : Path
      parts_lists = paths.map(&.parts)
      shared = [] of String
      max = parts_lists.min_of(&.size)
      max.times do |i|
        candidate = parts_lists.first[i]
        break unless parts_lists.all? { |parts| parts[i] == candidate }
        shared << candidate
      end
      shared.empty? ? Path["/"] : Path[shared.join(File::SEPARATOR)]
    end

    private def template_syntax?(source : String) : Bool
      source.includes?("{{") || source.includes?("{%")
    end

    private def collect_models : Array(Marten::DB::Model.class)
      models = [] of Marten::DB::Model.class
      Marten.apps.app_configs.each do |app_config|
        app_config.models.each { |model| models << model }
      end
      models
    end
  end
end
