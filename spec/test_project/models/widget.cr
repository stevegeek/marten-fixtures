class Widget < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255, blank: false, null: false
  field :note, :string, max_size: 255, blank: true, null: true

  with_timestamp_fields

  db_table "widgets"
end
