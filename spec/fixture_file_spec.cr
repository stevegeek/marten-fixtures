require "./spec_helper"

private def workspace_models : Array(Marten::DB::Model.class)
  [Account, User, Post, Tag, Leaf, Extra] of Marten::DB::Model.class
end

describe MartenFixtures::FixtureFile do
  it "derives a bare table name from a top-level YAML file" do
    file = MartenFixtures::FixtureFile.new(Path["spec/fixtures/accounts.yml"], workspace_models)
    file.table_name.should eq("accounts")
    file.model_class.should eq(Account)
  end

  it "underscores a subdirectory path into the table name" do
    file = MartenFixtures::FixtureFile.new(Path["spec/fixtures/subdir/extras.yml"], workspace_models)
    file.table_name.should eq("subdir_extras")
    file.model_class.should eq(Extra)
  end

  it "raises Error::UnknownTable when no model matches the derived table name" do
    expect_raises(MartenFixtures::Error::UnknownTable, /no model found/i) do
      MartenFixtures::FixtureFile.new(Path["spec/fixtures/nope.yml"], workspace_models)
    end
  end

  it "falls back to the bare stem when the path contains no 'fixtures' ancestor directory" do
    file = MartenFixtures::FixtureFile.new(Path["/some/random/place/accounts.yml"], workspace_models)
    file.table_name.should eq("accounts")
    file.model_class.should eq(Account)
  end
end
