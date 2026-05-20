require "./spec_helper"

private class FixtureAccessorHost
  include MartenFixtures::Accessors
end

describe MartenFixtures::Accessors do
  it "returns the model instance whose pk matches the label" do
    MartenFixtures::Loader.new([
      Path["spec/fixtures/accounts.yml"],
      Path["spec/fixtures/users.yml"],
    ]).load

    host = FixtureAccessorHost.new
    david = host.fixture(User, :david).as(User)
    david.name.should eq("David")
    david.pk.should eq(MartenFixtures::Label.identify("david"))
  end

  it "raises Marten's RecordNotFound when the label has no row" do
    host = FixtureAccessorHost.new
    expect_raises(Marten::DB::Errors::RecordNotFound) do
      host.fixture(User, :nobody)
    end
  end
end
