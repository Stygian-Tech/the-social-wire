import Foundation
import Testing
@testable import WireCore

@Suite("The Wire cursor codec")
struct WireCursorCodecTests {
  private let codec = try! WireCursorCodec(secret: String(repeating: "s", count: 32))

  @Test("round trips generation, language, and next ordinal")
  func roundTrip() throws {
    let cursor = WireCursor(generationID: UUID().uuidString, language: "en", nextOrdinal: 40)
    #expect(try codec.decode(codec.encode(cursor)) == cursor)
  }

  @Test("rejects malformed and oversized cursors")
  func rejectsMalformed() {
    #expect(throws: WireCursorError.malformed) { try codec.decode("not+base64") }
    #expect(throws: WireCursorError.malformed) {
      try codec.decode(String(repeating: "a", count: 4_097))
    }
  }

  @Test("rejects tampering and the wrong secret")
  func rejectsTampering() throws {
    let cursor = WireCursor(generationID: "generation", language: "en", nextOrdinal: 10)
    let encoded = try codec.encode(cursor)
    let tampered = encoded.dropLast() + (encoded.last == "a" ? "b" : "a")
    #expect(throws: WireCursorError.invalidSignature) { try codec.decode(String(tampered)) }
    let other = try WireCursorCodec(secret: String(repeating: "x", count: 32))
    #expect(throws: WireCursorError.invalidSignature) { try other.decode(encoded) }
  }

  @Test("rejects invalid fields")
  func rejectsInvalidPayload() {
    let cursor = WireCursor(generationID: "generation", language: "en", nextOrdinal: -1)
    #expect(throws: WireCursorError.invalidPayload) { try codec.encode(cursor) }
  }

  @Test("requires at least 256 bits of secret material")
  func rejectsShortSecret() {
    #expect(throws: WireCursorError.invalidSecret) { try WireCursorCodec(secret: "short") }
  }
}
