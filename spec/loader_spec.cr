require "./spec_helper"

describe MartenFixtures::Loader do
  it "registers every label across all files before any insert (pass 1 / pass 2 split)" do
    files = [
      Path["spec/fixtures/accounts.yml"],
      Path["spec/fixtures/users.yml"],
    ]
    loader = MartenFixtures::Loader.new(files)

    Account.all.size.should eq(0)
    User.all.size.should eq(0)

    loader.load

    loader.label_registry.lookup(Account, "engineering").should eq(
      MartenFixtures::Label.identify("engineering")
    )
    loader.label_registry.lookup(User, "david").should eq(
      MartenFixtures::Label.identify("david")
    )
    Account.all.size.should eq(2)
    User.all.size.should eq(2)
  end

  it "resolves a cross-file FK reference even when the dependent file is loaded first" do
    files = [
      Path["spec/fixtures/posts.yml"],
      Path["spec/fixtures/users.yml"],
      Path["spec/fixtures/accounts.yml"],
    ]

    MartenFixtures::Loader.new(files).load

    welcome = Post.get!(pk: MartenFixtures::Label.identify("welcome"))
    welcome.author_id.should eq(MartenFixtures::Label.identify("david"))
  end

  it "raises Error when a fixture file's top-level YAML is a sequence (not a mapping)" do
    bad_dir = Path[Dir.tempdir] / "marten_fixtures_loader_spec_#{Random::Secure.hex}"
    Dir.mkdir_p(bad_dir.to_s)
    bad_file = bad_dir / "accounts.yml"
    File.write(bad_file.to_s, "- item1\n- item2\n")

    expect_raises(MartenFixtures::Error, /must contain a YAML mapping/) do
      MartenFixtures::Loader.new([bad_file]).load
    end
  ensure
    FileUtils.rm_rf(bad_dir.to_s) if bad_dir
  end

  it "raises Error when a row's attributes are not a YAML mapping" do
    bad_dir = Path[Dir.tempdir] / "marten_fixtures_loader_spec_#{Random::Secure.hex}"
    Dir.mkdir_p(bad_dir.to_s)
    bad_file = bad_dir / "accounts.yml"
    File.write(bad_file.to_s, "engineering: \"not a map\"\n")

    expect_raises(MartenFixtures::Error, /must be a YAML mapping of attributes/) do
      MartenFixtures::Loader.new([bad_file]).load
    end
  ensure
    FileUtils.rm_rf(bad_dir.to_s) if bad_dir
  end

  it "treats an empty / null YAML file as zero rows and does not raise" do
    empty_dir = Path[Dir.tempdir] / "marten_fixtures_loader_spec_#{Random::Secure.hex}"
    Dir.mkdir_p(empty_dir.to_s)
    empty_file = empty_dir / "accounts.yml"
    File.write(empty_file.to_s, "")

    MartenFixtures::Loader.new([empty_file]).load

    Account.all.size.should eq(0)
  ensure
    FileUtils.rm_rf(empty_dir.to_s) if empty_dir
  end

  it "uses the evaluator pre-set on the configuration instead of building a CrinjaEvaluator" do
    plain = MartenFixtures::PlainEvaluator.new
    MartenFixtures.configuration.evaluator = plain

    MartenFixtures::Loader.new([Path["spec/fixtures/accounts.yml"]]).load

    Account.all.size.should eq(2)
    # Sanity: the same evaluator instance survives across the load
    MartenFixtures.configuration.evaluator.should be(plain)
  end

  describe "topological sort (C1)" do
    it "inserts dependencies before dependents regardless of caller-supplied file order" do
      # leaves → {posts, tags}; posts/tags → users; users → accounts.
      # Caller passes them in the alphabetical order that `Dir.glob.sort`
      # would yield, which puts leaves before its dependencies.
      files = [
        Path["spec/fixtures/accounts.yml"],
        Path["spec/fixtures/leaves.yml"],
        Path["spec/fixtures/posts.yml"],
        Path["spec/fixtures/tags.yml"],
        Path["spec/fixtures/users.yml"],
      ]

      MartenFixtures::Loader.new(files).load

      Account.all.size.should eq(2)
      User.all.size.should eq(2)
      Post.all.size.should eq(2)
      Tag.all.size.should eq(1)
      Leaf.all.size.should eq(3)
    end

    it "tolerates two FKs from the same model to the same parent (Kahn dedup, C1 round-2)" do
      # Simulates a model with audit columns like `created_by` AND
      # `updated_by`, both → User. Before the round-2 dedup fix the
      # dependents array would contain Post twice, causing Kahn to
      # double-enqueue and report a spurious cycle.
      extra_edges = {} of Marten::DB::Model.class => Array(Marten::DB::Model.class)
      extra_edges[Post] = [User] of Marten::DB::Model.class

      loader = MartenFixtures::Loader.new([] of Path)
      ordered = loader.topo_sort_for_spec([User, Post, Account] of Marten::DB::Model.class, extra_edges)

      ordered.size.should eq(3)
      ordered.index!(Account).should be < ordered.index!(User)
      ordered.index!(User).should be < ordered.index!(Post)
    end

    it "raises Error with the actual cycle path when models form a dependency cycle (H3 round-2)" do
      # Use Account + Extra (neither has any real FK to each other or to
      # User) so the cycle in the error message is unambiguous. Inject
      # Account -> Extra and Extra -> Account to close a 2-cycle.
      extra_edges = {} of Marten::DB::Model.class => Array(Marten::DB::Model.class)
      extra_edges[Account] = [Extra] of Marten::DB::Model.class
      extra_edges[Extra] = [Account] of Marten::DB::Model.class

      loader = MartenFixtures::Loader.new([] of Path)
      expect_raises(
        MartenFixtures::Error,
        /Fixture model dependency cycle: (Account -> Extra -> Account|Extra -> Account -> Extra)/,
      ) do
        loader.topo_sort_for_spec([Account, Extra] of Marten::DB::Model.class, extra_edges)
      end
    end

    it "load_all returns rows in FK order even when alphabetical file order would FK-violate" do
      # Place the tmp dir under a parent named `fixtures` so that
      # FixtureFile#derive_table_name picks up the subdir prefix
      # correctly. Alphabetical order of the YAMLs is
      # accounts → leaves → posts → tags → users — which puts leaves
      # before its dependencies. The topological sort must still produce
      # a working insert.
      tmp_root = Path[Dir.tempdir] / "marten_fixtures_topo_#{Random::Secure.hex}"
      tmp_dir = tmp_root / "fixtures"
      Dir.mkdir_p(tmp_dir.to_s)
      %w[leaves accounts posts tags users].each do |name|
        File.write((tmp_dir / "#{name}.yml").to_s, File.read(Path["spec/fixtures/#{name}.yml"].to_s))
      end

      MartenFixtures.load_all(tmp_dir.to_s)

      Account.all.size.should eq(2)
      User.all.size.should eq(2)
      Post.all.size.should eq(2)
      Tag.all.size.should eq(1)
      Leaf.all.size.should eq(3)
    ensure
      FileUtils.rm_rf(tmp_root.to_s) if tmp_root
    end
  end
end
