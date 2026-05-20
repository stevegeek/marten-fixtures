require "digest/crc32"
require "uuid"

module MartenFixtures
  # CRC32-based label → primary-key derivation, byte-compatible with Rails'
  # `ActiveRecord::FixtureSet.identify`.
  module Label
    # Mask used by Rails' identifier (2**30 - 1) — fits inside an INT4 column
    # and leaves room for application-assigned ids above the mask.
    MAX_ID = (2_i64 ** 30) - 1

    # Deterministic v5 namespace borrowed from the RFC 4122 example (DNS
    # namespace). Matches Rails' UUID identifier so the same label collapses
    # to the same UUID in either ecosystem.
    UUID_NAMESPACE = ::UUID.new("6ba7b810-9dad-11d1-80b4-00c04fd430c8")

    def self.identify(label : String) : Int64
      Digest::CRC32.checksum(label).to_i64 % MAX_ID
    end

    def self.identify(label : String, pk_field : Marten::DB::Field::Base) : Int64 | String
      if pk_field.is_a?(Marten::DB::Field::UUID)
        ::UUID.v5(label, UUID_NAMESPACE).to_s
      else
        identify(label)
      end
    end
  end
end
