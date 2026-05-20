require "./spec_helper"

private class UnsupportedAdapterInserter < MartenFixtures::Inserter
  protected def adapter_kind : Symbol
    :unknown
  end
end

describe MartenFixtures::Inserter do
  it "bulk-inserts rows on the configured backend with FK constraints relaxed" do
    user_pk = MartenFixtures::Label.identify("david")
    account_pk = MartenFixtures::Label.identify("engineering")
    now = Time.utc

    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [
      {
        "id"         => account_pk.as(::DB::Any),
        "name"       => "Engineering".as(::DB::Any),
        "created_at" => now.as(::DB::Any),
        "updated_at" => now.as(::DB::Any),
      },
    ]
    rows_by_model[User] = [
      {
        "id"              => user_pk.as(::DB::Any),
        "name"            => "David".as(::DB::Any),
        "email"           => "david@example.com".as(::DB::Any),
        "account_id"      => account_pk.as(::DB::Any),
        "password_digest" => "x".as(::DB::Any),
        "created_at"      => now.as(::DB::Any),
        "updated_at"      => now.as(::DB::Any),
      },
    ]

    connection = Marten::DB::Connection.default
    MartenFixtures::Inserter.new(connection).insert_all(rows_by_model)

    User.all.size.should eq(1)
    Account.all.size.should eq(1)
    User.get!(pk: user_pk).account_id.should eq(account_pk)
  end

  it "raises Error from with_constraints_disabled when the adapter kind is unrecognised" do
    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [
      {
        "id"         => 1_i64.as(::DB::Any),
        "name"       => "x".as(::DB::Any),
        "created_at" => Time.utc.as(::DB::Any),
        "updated_at" => Time.utc.as(::DB::Any),
      },
    ]

    expect_raises(MartenFixtures::Error, /MySQL not supported/) do
      UnsupportedAdapterInserter.new(Marten::DB::Connection.default).insert_all(rows_by_model)
    end
  end

  it "bumps Postgres sequences past the highest inserted id (Postgres only)" do
    pending!("Postgres-only sequence bump path") unless BACKEND == "postgres"

    seeded_pk = MartenFixtures::Label.identify("seed_account")
    now = Time.utc

    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [
      {
        "id"         => seeded_pk.as(::DB::Any),
        "name"       => "Seed".as(::DB::Any),
        "created_at" => now.as(::DB::Any),
        "updated_at" => now.as(::DB::Any),
      },
    ]

    connection = Marten::DB::Connection.default
    MartenFixtures::Inserter.new(connection).insert_all(rows_by_model)

    follow_up = Account.create!(name: "After bump")
    follow_up.pk.as(Int64).should be > seeded_pk
  end
end
