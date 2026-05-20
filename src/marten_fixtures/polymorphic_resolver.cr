module MartenFixtures
  # Translates the fixture-level polymorphic shorthand `"label (Type)"`
  # into the two-column `_type` / `_id` representation Marten stores.
  #
  # Short type names like `Post` are matched against the field's closed
  # target list via either exact `name == short` or `name.ends_with?("::#{short}")`,
  # so namespaced models (e.g. `Books::Leafables::Page`) can be referenced
  # by their leaf class.
  module PolymorphicResolver
    POLY_VALUE_RE = /\A(.+?)\s*\((\w+)\)\z/

    # Parses `"welcome (Post)"` into `{"welcome", "Post"}`. Returns nil if
    # the value does not carry a `(Type)` suffix.
    def self.parse_value(value : ::String) : Tuple(::String, ::String)?
      if md = POLY_VALUE_RE.match(value)
        {md[1], md[2]}
      end
    end

    # Returns a copy of the closed target list for a polymorphic field.
    # Wraps the private `@to` ivar so callers do not need to reach into
    # Marten's internals; this is the single fragile site that must be
    # updated if Marten exposes a public accessor in the future.
    #
    # The list is duplicated before returning so that caller-side mutation
    # cannot corrupt Marten's internal field state. Callers that only
    # iterate (the typical case) pay the small allocation cost for the
    # encapsulation guarantee.
    def self.target_models(poly_field : Marten::DB::Field::Polymorphic) : Array(Marten::DB::Model.class)
      poly_field.@to.dup
    end

    # Resolves a short type name to a `{FQCN, model_class}` tuple where
    # `model_class` is one of the field's allowed targets. Raises
    # `Error::UnknownPolymorphicType` listing the allowed names if no
    # target matches.
    #
    # Centralising the `@to` access here means callers (RowInterpolator)
    # never have to reach into the private ivar themselves.
    def self.resolve(
      poly_field : Marten::DB::Field::Polymorphic,
      short_type : ::String,
    ) : Tuple(::String, Marten::DB::Model.class)
      # Marten's `Field::Polymorphic` exposes `type_class(name)` but it
      # `find!`s and raises an opaque `Enumerable::NotFoundError`. To
      # surface a useful error we enumerate the closed target list via
      # the instance variable directly (no public accessor exists).
      candidates = poly_field.@to
      match = candidates.find { |model| model.name == short_type || model.name.ends_with?("::#{short_type}") }
      return {match.name, match} if match

      allowed = candidates.map(&.name).join(", ")
      raise Error::UnknownPolymorphicType.new(
        "Unknown polymorphic target #{short_type.inspect} for field #{poly_field.id.inspect}; " \
        "allowed: #{allowed}"
      )
    end
  end
end
