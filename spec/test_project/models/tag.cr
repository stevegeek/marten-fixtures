class Tag < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :label, :string, max_size: 255, blank: false, null: false
  field :author, :many_to_one, to: User, related: :tags, on_delete: :cascade

  with_timestamp_fields

  db_table "tags"
end
