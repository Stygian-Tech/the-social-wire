/// A timestamp identifier: 13 characters of sortable base32 encoding
/// 53 bits of microseconds since the Unix epoch and a 10-bit clock identifier.
public struct TID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    static let alphabet = Array("234567abcdefghijklmnopqrstuvwxyz")

    public let rawValue: String

    public init(_ string: String) throws {
        guard string.wholeMatch(of: /[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}/) != nil else {
            throw SyntaxError.invalidTID(string)
        }
        rawValue = string
    }

    public init(microseconds: UInt64, clockID: UInt16) {
        var value = (microseconds & 0x1F_FFFF_FFFF_FFFF) << 10 | UInt64(clockID & 0x3FF)
        var characters = [Character](repeating: "2", count: 13)
        for index in stride(from: 12, through: 0, by: -1) {
            characters[index] = Self.alphabet[Int(value & 0x1F)]
            value >>= 5
        }
        rawValue = String(characters)
    }

    /// Microseconds since the Unix epoch encoded in this TID.
    public var microseconds: UInt64 {
        let value = rawValue.reduce(UInt64(0)) { partial, character in
            partial << 5 | UInt64(Self.alphabet.firstIndex(of: character)!)
        }
        return value >> 10
    }

    public var description: String { rawValue }

    public static func < (lhs: TID, rhs: TID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
