import Foundation
import Testing

@testable import GatewayCore

@Suite("DPoPReplayGuard")
struct DPoPReplayGuardTests {
  @Test("fails closed at capacity without evicting live replay entries")
  func failsClosedAtCapacity() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let guardActor = DPoPReplayGuard(retention: 120, maximumEntries: 2)

    try await guardActor.consume(thumbprint: "key", jti: "first", now: now)
    try await guardActor.consume(thumbprint: "key", jti: "second", now: now)

    await #expect(throws: DPoPReplayGuard.ReplayError.capacityExceeded) {
      try await guardActor.consume(thumbprint: "key", jti: "third", now: now)
    }
    await #expect(throws: DPoPReplayGuard.ReplayError.replayed) {
      try await guardActor.consume(thumbprint: "key", jti: "first", now: now)
    }

    try await guardActor.consume(
      thumbprint: "key",
      jti: "third",
      now: now.addingTimeInterval(121)
    )
  }

  @Test("retains future-dated proofs through their full verifier acceptance window")
  func retainsFutureDatedProof() async throws {
    let firstUse = Date(timeIntervalSince1970: 1_000)
    let validUntil = firstUse.addingTimeInterval(240)
    let guardActor = DPoPReplayGuard(retention: 120, maximumEntries: 2)

    try await guardActor.consume(
      thumbprint: "key",
      jti: "future-proof",
      validUntil: validUntil,
      now: firstUse
    )

    await #expect(throws: DPoPReplayGuard.ReplayError.replayed) {
      try await guardActor.consume(
        thumbprint: "key",
        jti: "future-proof",
        validUntil: validUntil,
        now: firstUse.addingTimeInterval(121)
      )
    }
    await #expect(throws: DPoPReplayGuard.ReplayError.replayed) {
      try await guardActor.consume(
        thumbprint: "key",
        jti: "future-proof",
        validUntil: validUntil,
        now: validUntil
      )
    }

    try await guardActor.consume(
      thumbprint: "key",
      jti: "future-proof",
      validUntil: validUntil,
      now: validUntil.addingTimeInterval(0.001)
    )
  }
}
