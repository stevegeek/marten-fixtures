class Account < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255, blank: false, null: false

  with_timestamp_fields

  db_table "accounts"
end
