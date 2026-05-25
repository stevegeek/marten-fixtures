# MFR5: model with a String primary key (not UUID, not integer). Used
# to verify that explicit `id:` values supplied as YAML strings are
# preserved verbatim rather than coerced to Int64 just because they
# happen to be all-digit-looking. Pre-MFR5 `id: "42"` on a String-PK
# model silently became `42_i64`, mismatching the column type at the
# Marten/DB layer.
class Coupon < Marten::Model
  field :code, :string, max_size: 64, primary_key: true, blank: false, null: false
  field :name, :string, max_size: 255, blank: false, null: false

  with_timestamp_fields

  db_table "coupons"
end
