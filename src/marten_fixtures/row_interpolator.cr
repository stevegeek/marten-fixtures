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
          values[field.db_column!] = field.to_db(coerce_for_field(field, value))
        end
      end

      ensure_pk(values, label)
      ensure_timestamps(values)

      values
    end

    # L2: cap the "known fields" list to the first 20 entries (plus a
    # "and N more" suffix). For wide models the unbounded list buried
    # the misspelled-field signal in screens of column names; 20 is
    # enough to spot the typo by eye, and the suffix preserves the
    # signal that the model has more fields than the message shows.
    KNOWN_FIELDS_SAMPLE = 20

    private def lookup_field(key : ::String) : Marten::DB::Field::Base
      @model_class.get_field(key)
    rescue Marten::DB::Errors::UnknownField
      ids = @model_class.fields.map(&.id)
      known = if ids.size > KNOWN_FIELDS_SAMPLE
                "#{ids.first(KNOWN_FIELDS_SAMPLE).join(", ")} (and #{ids.size - KNOWN_FIELDS_SAMPLE} more)"
              else
                ids.join(", ")
              end
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

    # H3: Marten's `Field::JSON#to_db`, `Field::Duration#to_db`, and
    # `Field::Date#to_db` reject YAML's native union types. For each
    # of those fields, convert the raw YAML value into the type the
    # field expects:
    #
    # - JSON: serialise the raw value via `value.to_json` and parse back
    #   into `JSON::Any`. This handles nested hashes / arrays / scalars
    #   uniformly, including `nil`.
    # - Duration: accept a numeric value as a count of seconds (the
    #   most natural YAML literal) OR an ISO-8601-ish duration string
    #   ("PT5M30S", "5m30s") parsed via `Time::Span` helpers.
    # - Date: YAML date/datetime literals already parse to `Time`,
    #   which `Field::Date#to_db` accepts. Strings that look like
    #   ISO-8601 dates are parsed; everything else is handed to `to_db`
    #   so the field's own validation surfaces a clear error.
    private def coerce_for_field(field : Marten::DB::Field::Base, value : YAML::Any)
      case field
      when Marten::DB::Field::JSON
        coerce_json(value)
      when Marten::DB::Field::Duration
        coerce_duration(value)
      when Marten::DB::Field::Date
        coerce_date(value)
      else
        yaml_to_native(value)
      end
    end

    private def coerce_json(value : YAML::Any) : ::JSON::Any?
      raw = value.raw
      return nil if raw.nil?
      ::JSON.parse(value.to_json)
    end

    private def coerce_duration(value : YAML::Any) : Time::Span?
      raw = value.raw
      case raw
      when Nil
        nil
      when ::Int
        Time::Span.new(seconds: raw.to_i64)
      when ::Float
        # Permit fractional seconds: 1.5 -> 1.5s.
        Time::Span.new(nanoseconds: (raw * 1_000_000_000).to_i64)
      when ::String
        parse_duration_string(raw)
      else
        raise Error.new(
          "Duration field #{field_label}: unsupported YAML value type #{raw.class} (#{raw.inspect}); " \
          "supply a number of seconds or an ISO-8601-style string (e.g. \"PT5M30S\" or \"1h30m\")"
        )
      end
    end

    # Accepts ISO-8601 `PT…` durations and the common shorthand
    # `Nh`/`Nm`/`Ns`/`Nms`/`Nus`/`Nns` (combinable, e.g. `1h30m15s`).
    # A bare integer-or-float string is treated as a count of seconds.
    private def parse_duration_string(raw : ::String) : Time::Span
      trimmed = raw.strip
      raise Error.new("Duration field #{field_label}: empty string") if trimmed.empty?

      # Bare numeric → seconds.
      if seconds_i = trimmed.to_i64?
        return Time::Span.new(seconds: seconds_i)
      end
      if seconds_f = trimmed.to_f64?
        return Time::Span.new(nanoseconds: (seconds_f * 1_000_000_000).to_i64)
      end

      iso_or_shorthand = trimmed
      iso_or_shorthand = iso_or_shorthand[2..] if iso_or_shorthand.starts_with?("PT") || iso_or_shorthand.starts_with?("pt")
      iso_or_shorthand = iso_or_shorthand[1..] if iso_or_shorthand.starts_with?("P") || iso_or_shorthand.starts_with?("p")

      total = Time::Span.zero
      remaining = iso_or_shorthand
      # Order matters: 'ms' / 'us' / 'ns' must match before 'm' / 's'.
      patterns = [
        {/\A(\d+(?:\.\d+)?)ns/i, ->(v : Float64) { Time::Span.new(nanoseconds: v.to_i64) }},
        {/\A(\d+(?:\.\d+)?)us/i, ->(v : Float64) { Time::Span.new(nanoseconds: (v * 1_000).to_i64) }},
        {/\A(\d+(?:\.\d+)?)ms/i, ->(v : Float64) { Time::Span.new(nanoseconds: (v * 1_000_000).to_i64) }},
        {/\A(\d+(?:\.\d+)?)h/i, ->(v : Float64) { Time::Span.new(nanoseconds: (v * 3_600 * 1_000_000_000).to_i64) }},
        {/\A(\d+(?:\.\d+)?)m(?!s)/i, ->(v : Float64) { Time::Span.new(nanoseconds: (v * 60 * 1_000_000_000).to_i64) }},
        {/\A(\d+(?:\.\d+)?)s/i, ->(v : Float64) { Time::Span.new(nanoseconds: (v * 1_000_000_000).to_i64) }},
      ]

      until remaining.empty?
        matched = false
        patterns.each do |(pattern, builder)|
          if match = remaining.match(pattern)
            total += builder.call(match[1].to_f64)
            remaining = remaining[match[0].size..]
            matched = true
            break
          end
        end
        unless matched
          raise Error.new(
            "Duration field #{field_label}: unparseable token #{remaining.inspect} in #{raw.inspect}; " \
            "supported forms: seconds (number), ISO-8601 (\"PT5M30S\"), or shorthand (\"1h30m15s\")"
          )
        end
      end

      total
    end

    private def coerce_date(value : YAML::Any)
      raw = value.raw
      case raw
      when Nil
        nil
      when Time
        # YAML parses `2026-05-20` literals to `Time` already; `Field::Date#to_db`
        # accepts Time. Pass through unchanged.
        raw
      when ::String
        # Try ISO-8601 date / date-time parsing. Fall back to the raw
        # value (which `to_db` will then reject with its own clear
        # error) so we don't silently swallow malformed input here.
        parsed = parse_date_string(raw)
        parsed || raw
      else
        raw
      end
    end

    private def parse_date_string(raw : ::String) : Time?
      # Common, unambiguous shapes. Order matters: try the most
      # specific first. `Time.parse` raises on failure; rescue silently
      # because the caller falls back to handing the raw value to
      # `to_db` (which produces its own descriptive error).
      [
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d",
      ].each do |format|
        begin
          return Time.parse(raw, format, Time::Location::UTC)
        rescue Time::Format::Error
          next
        end
      end
      nil
    end

    private def field_label : ::String
      "#{@model_class.name}"
    end
  end
end
