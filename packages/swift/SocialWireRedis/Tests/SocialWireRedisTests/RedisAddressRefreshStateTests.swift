import Foundation
import Testing
@testable import SocialWireRedis

@Suite("Redis address refresh state")
struct RedisAddressRefreshStateTests {
  @Test("Allows one DNS refresh per cooldown window")
  func cooldown() {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    var state = RedisAddressRefreshState(cooldown: 5)

    let firstAttempt = state.beginRefreshIfAllowed(now: startedAt)
    let attemptDuringCooldown = state.beginRefreshIfAllowed(
      now: startedAt.addingTimeInterval(4.9)
    )
    let attemptAfterCooldown = state.beginRefreshIfAllowed(
      now: startedAt.addingTimeInterval(5)
    )

    #expect(firstAttempt)
    #expect(!attemptDuringCooldown)
    #expect(attemptAfterCooldown)
  }
}
