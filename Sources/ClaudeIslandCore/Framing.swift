import Foundation

/// Wire format: 4-byte little-endian UInt32 length, then that many bytes of
/// JSON. One payload per connection; the client closes immediately after.
///
/// The prefix is not strictly required — read-to-EOF would work — but it lets
/// the server reject an absurd length before allocating for it.
public enum Framing {
    /// A `Write` tool_input carries an entire file body, so the cap has to be
    /// generous. Beyond this we drop the payload rather than allocate.
    public static let maxPayloadBytes: UInt32 = 16 << 20

    public static let prefixLength = 4

    public static func encodePrefix(_ length: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 24),
        ]
    }

    public static func decodePrefix(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.count >= 4 else { return nil }
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
    }
}
