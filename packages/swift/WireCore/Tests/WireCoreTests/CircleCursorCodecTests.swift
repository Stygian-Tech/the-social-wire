import Foundation
import Testing

@testable import WireCore

@Suite("Your Circle cursor codec")
struct CircleCursorCodecTests {
  private let codec = try! CircleCursorCodec(secret: String(repeating: "c", count: 32))
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("round trips snapshot, generation, language, ordinal, and expiry")
  func roundTrip() throws {
    let cursor = CircleCursor(
      snapshotID: "snapshot-1",
      generationID: "generation-1",
      language: "en",
      nextOrdinal: 40,
      expiresAt: now.addingTimeInterval(600)
    )
    let encoded = try codec.encode(cursor, viewerID: "did:plc:viewer")
    #expect(
      try codec.decode(encoded, viewerID: "did:plc:viewer", now: now) == cursor
    )
  }

  @Test("binds a cursor to one normalized viewer without exposing the DID")
  func viewerBinding() throws {
    let viewer = "did:plc:private-viewer"
    let cursor = CircleCursor(
      snapshotID: "snapshot",
      generationID: "generation",
      language: "und",
      nextOrdinal: 1,
      expiresAt: now.addingTimeInterval(600)
    )
    let encoded = try codec.encode(cursor, viewerID: viewer)
    #expect(try codec.decode(encoded, viewerID: viewer.uppercased(), now: now) == cursor)
    #expect(throws: CircleCursorError.viewerMismatch) {
      try codec.decode(encoded, viewerID: "did:plc:someone-else", now: now)
    }
    let payloadPart = try #require(encoded.split(separator: ".").first)
    var base64 = String(payloadPart).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    let payload = try #require(Data(base64Encoded: base64))
    #expect(!String(decoding: payload, as: UTF8.self).contains(viewer))
  }

  @Test("rejects an expired otherwise valid cursor")
  func expiry() throws {
    let cursor = CircleCursor(
      snapshotID: "snapshot",
      generationID: "generation",
      language: "en",
      nextOrdinal: 0,
      expiresAt: now.addingTimeInterval(1)
    )
    let encoded = try codec.encode(cursor, viewerID: "did:plc:viewer")
    #expect(throws: CircleCursorError.expired) {
      try codec.decode(encoded, viewerID: "did:plc:viewer", now: now.addingTimeInterval(1))
    }
  }

  @Test("rejects tampering and a different signing secret")
  func signature() throws {
    let cursor = CircleCursor(
      snapshotID: "snapshot",
      generationID: "generation",
      language: "en",
      nextOrdinal: 5,
      expiresAt: now.addingTimeInterval(600)
    )
    let encoded = try codec.encode(cursor, viewerID: "did:plc:viewer")
    let tampered = encoded.dropLast() + (encoded.last == "a" ? "b" : "a")
    #expect(throws: CircleCursorError.invalidSignature) {
      try codec.decode(String(tampered), viewerID: "did:plc:viewer", now: now)
    }
    let other = try CircleCursorCodec(secret: String(repeating: "x", count: 32))
    #expect(throws: CircleCursorError.invalidSignature) {
      try other.decode(encoded, viewerID: "did:plc:viewer", now: now)
    }
  }

  @Test("rejects malformed and invalid cursor fields")
  func invalidInput() {
    #expect(throws: CircleCursorError.malformed) {
      try codec.decode("not-a-cursor", viewerID: "did:plc:viewer", now: now)
    }
    #expect(throws: CircleCursorError.invalidPayload) {
      try codec.encode(
        CircleCursor(
          snapshotID: "",
          generationID: "generation",
          language: "en",
          nextOrdinal: -1,
          expiresAt: now.addingTimeInterval(600)
        ),
        viewerID: "did:plc:viewer"
      )
    }
  }

  @Test("requires at least 256 bits of signing material")
  func secretLength() {
    #expect(throws: CircleCursorError.invalidSecret) {
      try CircleCursorCodec(secret: "short")
    }
  }
}
