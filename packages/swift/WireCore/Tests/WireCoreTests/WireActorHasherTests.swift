import Foundation
import Testing
@testable import WireCore

@Suite("The Wire actor hasher")
struct WireActorHasherTests {
  @Test("is keyed, normalized, and deterministic")
  func deterministicHash() throws {
    let first = try WireActorHasher(secret: Data(repeating: 1, count: 32))
    let second = try WireActorHasher(secret: Data(repeating: 2, count: 32))
    #expect(try first.hash(" DID:PLC:Example ") == first.hash("did:plc:example"))
    #expect(try first.hash("did:plc:example") != second.hash("did:plc:example"))
    #expect(try first.hash("did:plc:example").hasPrefix("h1:"))
  }

  @Test("rejects short secrets and empty actors")
  func rejectsInvalidInput() throws {
    #expect(throws: WireActorHasherError.invalidSecret) {
      try WireActorHasher(secret: Data(repeating: 1, count: 31))
    }
    let hasher = try WireActorHasher(secret: Data(repeating: 1, count: 32))
    #expect(throws: WireActorHasherError.invalidActorID) { try hasher.hash("  ") }
  }
}
