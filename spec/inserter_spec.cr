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

  # M1: with the three-arg setval form, an empty fixture batch (no rows
  # for this model) should leave the sequence so that the next
  # application-driven insert returns id=1, not id=2. The previous
  # two-arg `setval(seq, GREATEST(MAX,1))` form marked the sequence as
  # "called" even when MAX was NULL, advancing the next nextval to 2.
  it "leaves an empty table's sequence so the next application insert receives id=1 (M1, Postgres only)" do
    pending!("Postgres-only sequence bump path") unless BACKEND == "postgres"

    # No rows seeded — but the bump still runs (insert_all iterates the
    # supplied hash; we supply an empty array to bump the sequence
    # without inserting anything).
    rows_by_model = {} of Marten::DB::Model.class => Array(Hash(String, ::DB::Any))
    rows_by_model[Account] = [] of Hash(String, ::DB::Any)

    connection = Marten::DB::Connection.default
    # Reset the sequence to a known-after-prior-load state by deleting
    # any rows and resetting the sequence to id=42 with is_called=true,
    # so a buggy two-arg setval would advance to id=43, while the
    # three-arg form with MAX=NULL would correctly fall back to 1.
    connection.open do |db|
      db.exec("DELETE FROM #{connection.quote(Account.db_table)}")
      db.exec(
        "SELECT setval(pg_get_serial_sequence(quote_ident($1), quote_ident($2)), 42, true)",
        Account.db_table, "id",
      )
    end

    MartenFixtures::Inserter.new(connection).insert_all(rows_by_model)

    follow_up = Account.create!(name: "After empty-table bump")
    # With the M1 three-arg setval, MAX is NULL → is_called=false →
    # next nextval = max_or_one = 1. Pre-fix the value would be 43
    # (or any value above 1, including 2 from a fresh sequence).
    follow_up.pk.as(Int64).should eq(1_i64)
  end
end
