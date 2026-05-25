require "digest/crc32"
require "uuid"

module MartenFixtures
  # CRC32-based label → primary-key derivation, byte-compatible with Rails'
  # `ActiveRecord::FixtureSet.identify`.
  module Label
    # Mask used by Rails' identifier (2**30 - 1) — fits inside an INT4 column
    # and leaves room for application-assigned ids above the mask.
    MAX_ID = (2_i64 ** 30) - 1

    # L9: Rails 7.x's `ActiveRecord::FixtureSet` derives UUID primary
    # keys via `Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE, label)`
    # — the OID namespace `6ba7b812-9dad-11d1-80b4-00c04fd430c8`, NOT
    # the DNS namespace this shard previously used. Switching matches
    # Rails byte-for-byte so the same label produces the same UUID in
    # both ecosystems (the documented "Rails parity" guarantee in the
    # README).
    OID_NAMESPACE = ::UUID.new("6ba7b812-9dad-11d1-80b4-00c04fd430c8")
    # :nodoc:
    @[Deprecated("Use OID_NAMESPACE (Rails 7.x uses the OID namespace, not DNS)")]
    UUID_NAMESPACE = OID_NAMESPACE

    def self.identify(label : String) : Int64
      Digest::CRC32.checksum(label).to_i64 % MAX_ID
    end

    def self.identify(label : String, pk_field : Marten::DB::Field::Base) : Int64 | String
      if pk_field.is_a?(Marten::DB::Field::UUID)
        ::UUID.v5(label, OID_NAMESPACE).to_s
      else
        identify(label)
      end
    end
  end
end
