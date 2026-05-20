module MartenFixtures
  # Top-level shard configuration. Mutated via `MartenFixtures.configure`.
  class Configuration
    VALID_TIMESTAMP_POLICIES = {:auto, :skip, :required}

    property fixtures_path : Path = Path["spec/fixtures"]
    getter timestamp_policy : Symbol = :auto
    property evaluator : MartenFixtures::Evaluator?

    def fixtures_path=(value : String | Path)
      @fixtures_path = value.is_a?(Path) ? value : Path[value]
    end

    def timestamp_policy=(value : Symbol)
      unless VALID_TIMESTAMP_POLICIES.includes?(value)
        raise ArgumentError.new(
          "Invalid timestamp_policy #{value.inspect}; expected one of #{VALID_TIMESTAMP_POLICIES}"
        )
      end
      @timestamp_policy = value
    end
  end
end
