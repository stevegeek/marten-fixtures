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
    # Wraps the private `@to` ivar (see `read_to_ivar`) so callers do not
    # need to reach into Marten's internals.
    #
    # The list is duplicated before returning so that caller-side mutation
    # cannot corrupt Marten's internal field state. Callers that only
    # iterate (the typical case) pay the small allocation cost for the
    # encapsulation guarantee.
    def self.target_models(poly_field : Marten::DB::Field::Polymorphic) : Array(Marten::DB::Model.class)
      read_to_ivar(poly_field).dup
    end

    # Resolves a short type name to a `{FQCN, model_class}` tuple where
    # `model_class` is one of the field's allowed targets. Raises
    # `Error::UnknownPolymorphicType` listing the allowed names if no
    # target matches.
    #
    # Reads the target list via the same `read_to_ivar` helper as
    # `target_models` so the single fragile `@to` access lives in one
    # place (M3). Marten's `Field::Polymorphic` exposes `type_class(name)`
    # but it `find!`s and raises an opaque `Enumerable::NotFoundError`,
    # which is why we enumerate ourselves and emit a useful error here.
    def self.resolve(
      poly_field : Marten::DB::Field::Polymorphic,
      short_type : ::String,
    ) : Tuple(::String, Marten::DB::Model.class)
      candidates = read_to_ivar(poly_field)
      match = candidates.find { |model| model.name == short_type || model.name.ends_with?("::#{short_type}") }
      return {match.name, match} if match

      allowed = candidates.map(&.name).join(", ")
      raise Error::UnknownPolymorphicType.new(
        "Unknown polymorphic target #{short_type.inspect} for field #{poly_field.id.inspect}; " \
        "allowed: #{allowed}"
      )
    end

    # M3: SINGLE fragile site for reaching into Marten's private `@to`
    # ivar. Both `target_models` and `resolve` route through here, so the
    # day Marten renames the ivar or surfaces a public accessor we only
    # have to update this method. Returns the live array — callers that
    # need a copy (the public `target_models` API) `.dup` themselves;
    # callers that only iterate (the public `resolve` API) get the live
    # reference and pay zero allocation cost.
    private def self.read_to_ivar(
      poly_field : Marten::DB::Field::Polymorphic,
    ) : Array(Marten::DB::Model.class)
      poly_field.@to
    end
  end
end
