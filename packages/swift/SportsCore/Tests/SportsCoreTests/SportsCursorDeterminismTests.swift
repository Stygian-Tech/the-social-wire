import Foundation
import SportsCore
import Testing

struct SportsCursorDeterminismTests {
  @Test func encodingIdenticalContextIsDeterministicAndRoundTrips() throws {
    let codec = try SportsCursorCodec(secret: String(repeating: "s", count: 32))
    let cursor = SportsCursor(generationID: "generation", language: "en", preferenceFingerprint: "prefs", viewerScope: "viewer", nextOrdinal: 2, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    let encoded = try codec.encode(cursor)
    for _ in 0..<20 { #expect(try codec.encode(cursor) == encoded) }
    #expect(try codec.decode(encoded, language: "en", preferenceFingerprint: "prefs", viewerScope: "viewer", now: Date(timeIntervalSince1970: 1_900_000_000)) == cursor)
  }
}
