class User < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255, blank: false, null: false
  field :email, :string, max_size: 255, blank: false, null: false
  field :account, :many_to_one, to: Account, related: :users, on_delete: :cascade
  field :password_digest, :string, max_size: 255, blank: false, null: false

  with_timestamp_fields

  db_table "users"
end
