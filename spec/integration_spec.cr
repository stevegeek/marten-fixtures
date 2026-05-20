require "./spec_helper"

describe "MartenFixtures.load_all" do
  it "loads every fixture under the directory and persists every row" do
    MartenFixtures.load_all("spec/fixtures")

    Account.all.size.should eq(2)
    User.all.size.should eq(2)
    Post.all.size.should eq(2)
    Tag.all.size.should eq(1)
    Leaf.all.size.should eq(3)
    Extra.all.size.should eq(1)
  end

  it "stores the polymorphic leaf row with a resolved _type/_id pair pointing at the right target row" do
    MartenFixtures.load_all("spec/fixtures")

    leaf = Leaf.get!(pk: MartenFixtures::Label.identify("lead_welcome"))
    leaf.leafable_type.should eq("Post")
    leaf.leafable_id.should eq(MartenFixtures::Label.identify("welcome"))

    tag_leaf = Leaf.get!(pk: MartenFixtures::Label.identify("lead_important"))
    tag_leaf.leafable_type.should eq("Tag")
    tag_leaf.leafable_id.should eq(MartenFixtures::Label.identify("important"))
  end
end

describe "MartenFixtures.load" do
  it "loads each supplied file path and persists the rows" do
    MartenFixtures.load(
      "spec/fixtures/accounts.yml",
      "spec/fixtures/users.yml",
    )

    Account.all.size.should eq(2)
    User.all.size.should eq(2)
    User.get!(pk: MartenFixtures::Label.identify("david")).account_id.should eq(
      MartenFixtures::Label.identify("engineering")
    )
  end
end
