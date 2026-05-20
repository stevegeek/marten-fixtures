class Post < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :title, :string, max_size: 255, blank: false, null: false
  field :body, :string, max_size: 1024, blank: false, null: false
  field :author, :many_to_one, to: User, related: :posts, on_delete: :cascade

  with_timestamp_fields

  db_table "posts"
end
