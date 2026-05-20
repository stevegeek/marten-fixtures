require "yaml"

module MartenFixtures
  # Translates one fixture row's raw YAML attributes into a hash keyed
  # by DB column name with values coerced through each field's `to_db`.
  #
  # Responsibilities:
  # - Validate that every supplied key maps to a known field on the model.
  # - Expand `ManyToOne` / `OneToOne` label refs into `<relation>_id` columns.
  # - Expand polymorphic shorthand `"label (Type)"` into the two-column
  #   `<field>_type` / `<field>_id` representation Marten stores.
  # - Inject the deterministic CRC32-derived `id` when the row omits it.
  # - Auto-fill `created_at` / `updated_at` columns per the timestamp policy.
  class RowInterpolator
    AUTO_TIMESTAMP_COLUMNS = {"created_at", "updated_at"}

    def initialize(
      @model_class : Marten::DB::Model.class,
      @label_registry : LabelRegistry,
      @timestamp_policy : Symbol,
    )
    end

    def interpolate(label : ::String, raw_attrs : Hash(::String, YAML::Any)) : Hash(::String, ::DB::Any)
      values = {} of ::String => ::DB::Any

      raw_attrs.each do |key, value|
        field = lookup_field(key)

        case field
        when Marten::DB::Field::Polymorphic
          assign_polymorphic(values, field, value)
        when Marten::DB::Field::ManyToOne, Marten::DB::Field::OneToOne
          assign_relation(values, field, value)
        else
          next unless field.db_column?
          values[field.db_column!] = field.to_db(yaml_to_native(value))
        end
      end

      ensure_pk(values, label)
      ensure_timestamps(values)

      values
    end

    private def lookup_field(key : ::String) : Marten::DB::Field::Base
      @model_class.get_field(key)
    rescue Marten::DB::Errors::UnknownField
      known = @model_class.fields.map(&.id).join(", ")
      raise Error::UnknownField.new(
        "Unknown fixture field #{key.inspect} on #{@model_class.name}; known fields: #{known}"
      )
    end

    private def assign_relation(
      values : Hash(::String, ::DB::Any),
      field : Marten::DB::Field::ManyToOne | Marten::DB::Field::OneToOne,
      value : YAML::Any,
    ) : Nil
      raw = value.raw
      column = field.db_column!

      if raw.is_a?(::String)
        pk = @label_registry.lookup(field.related_model, raw)
        values[column] = pk.as(::DB::Any)
      else
        values[column] = field.to_db(yaml_to_native(value))
      end
    end

    private def assign_polymorphic(
      values : Hash(::String, ::DB::Any),
      field : Marten::DB::Field::Polymorphic,
      value : YAML::Any,
    ) : Nil
      raw = value.raw
      unless raw.is_a?(::String)
        raise Error::UnknownPolymorphicType.new(
          "Polymorphic field #{field.id.inspect} requires a string value like \"label (Type)\""
        )
      end

      parsed = PolymorphicResolver.parse_value(raw)
      unless parsed
        raise Error::UnknownPolymorphicType.new(
          "Polymorphic value #{raw.inspect} on field #{field.id.inspect} must be in the form \"label (Type)\""
        )
      end

      label, short_type = parsed
      fqcn, target_model = PolymorphicResolver.resolve(field, short_type)
      pk = @label_registry.lookup(target_model, label)

      # Marten's polymorphic field always derives its physical columns as
      # `<field.id>_type` and `<field.id>_id`; no `db_column:` override exists
      # for polymorphic pairs (unlike plain ManyToOne which honours db_column!).
      values["#{field.id}_type"] = fqcn.as(::DB::Any)
      values["#{field.id}_id"] = pk.as(::DB::Any)
    end

    private def ensure_pk(values : Hash(::String, ::DB::Any), label : ::String) : Nil
      pk_field = @model_class.fields.find!(&.primary_key?)
      pk_col = pk_field.db_column!
      return if values.has_key?(pk_col)

      pk = @label_registry.lookup?(@model_class, label) ||
           Label.identify(label, pk_field)
      values[pk_col] = pk.as(::DB::Any)
    end

    private def ensure_timestamps(values : Hash(::String, ::DB::Any)) : Nil
      return if @timestamp_policy == :skip

      AUTO_TIMESTAMP_COLUMNS.each do |column|
        next if values.has_key?(column)

        field = field_for_column(column)
        next unless field

        case @timestamp_policy
        when :auto
          values[column] = field.to_db(Time.utc)
        when :required
          raise Error.new(
            "Fixture row is missing required timestamp column #{column.inspect} " \
            "on #{@model_class.name} (timestamp_policy = :required)"
          )
        end
      end
    end

    private def field_for_column(column : ::String) : Marten::DB::Field::Base?
      @model_class.fields.find { |field| field.db_column? && field.db_column! == column }
    end

    private def yaml_to_native(value : YAML::Any)
      value.raw
    end
  end
end
