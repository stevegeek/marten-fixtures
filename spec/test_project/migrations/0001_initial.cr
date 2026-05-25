class Migration::MartenFixturesSpec::V0001 < Marten::Migration
  def plan
    create_table :accounts do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 255, null: false
      column :created_at, :date_time, null: false
      column :updated_at, :date_time, null: false
    end

    create_table :users do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 255, null: false
      column :email, :string, max_size: 255, null: false
      column :account_id, :reference, to_table: :accounts, to_column: :id, null: false
      column :password_digest, :string, max_size: 255, null: false
      column :created_at, :date_time, null: false
      column :updated_at, :date_time, null: false
    end

    create_table :posts do
      column :id, :big_int, primary_key: true, auto: true
      column :title, :string, max_size: 255, null: false
      column :body, :string, max_size: 1024, null: false
      column :author_id, :reference, to_table: :users, to_column: :id, null: false
      column :created_at, :date_time, null: false
      column :updated_at, :date_time, null: false
    end

    create_table :tags do
      column :id, :big_int, primary_key: true, auto: true
      column :label, :string, max_size: 255, null: false
      column :author_id, :reference, to_table: :users, to_column: :id, null: false
      column :created_at, :date_time, null: false
      column :updated_at, :date_time, null: false
    end

    create_table :leaves do
      column :id, :big_int, primary_key: true, auto: true
      column :position, :int, null: false
      column :leafable_id, :big_int, null: false
      column :leafable_type, :string, max_size: 255, null: false
      column :created_at, :date_time, null: false
      column :updated_at, :date_time, null: false
    end

    create_table :subdir_extras do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 255, null: false
      column :created_at, :date_time, null: false
      column :updated_at, :date_time, null: false
    end

    create_table :samples do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 255, null: false
      column :metadata, :json, null: true
      column :ttl, :duration, null: true
      column :scheduled_on, :date, null: true
      column :created_at, :date_time, null: false
      column :updated_at, :date_time, null: false
    end

    create_table :widgets do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 255, null: false
      column :note, :string, max_size: 255, null: true
      column :created_at, :date_time, null: false
      column :updated_at, :date_time, null: false
    end

    create_table :categories do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 255, null: false
      column :parent_id, :reference, to_table: :categories, to_column: :id, null: true
      column :created_at, :date_time, null: false
      column :updated_at, :date_time, null: false
    end
  end
end
