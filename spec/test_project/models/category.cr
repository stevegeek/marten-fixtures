class Category < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255, blank: false, null: false
  # Self-FK: a category may have a parent category in the same table.
  # Used by the L4 spec to exercise within-file row ordering.
  field :parent, :many_to_one, to: Category, related: :children, on_delete: :cascade, null: true

  with_timestamp_fields

  db_table "categories"
end
