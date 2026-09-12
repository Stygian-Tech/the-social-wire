import Foundation
import Logging
import Testing

@testable import OperationsCore

@Suite("Role lease supervisor")
struct RoleLeaseSupervisorTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("configuration rejects unsafe renewal and retry intervals")
  func invalidConfiguration() {
    #expect(throws: RoleLeaseSupervisorError.invalidConfiguration) {
      _ = try RoleLeaseSupervisorConfiguration(
        role: "wire-rank", ownerID: "replica-a",
        leaseDuration: 5, renewInterval: 1, standbyRetryInterval: 1)
    }
    #expect(throws: RoleLeaseSupervisorError.invalidConfiguration) {
      _ = try RoleLeaseSupervisorConfiguration(
        role: "wire-rank", ownerID: "replica-a",
        leaseDuration: 30, renewInterval: 25, standbyRetryInterval: 1)
    }
    #expect(throws: RoleLeaseSupervisorError.invalidConfiguration) {
      _ = try RoleLeaseSupervisorConfiguration(
        role: "wire-rank", ownerID: "replica-a",
        leaseDuration: 10, renewInterval: 10, standbyRetryInterval: 1
      )
    }
    #expect(throws: RoleLeaseSupervisorError.invalidConfiguration) {
      _ = try RoleLeaseSupervisorConfiguration(
        role: "wire-rank", ownerID: "replica-a",
        leaseDuration: 10, renewInterval: 3, standbyRetryInterval: 0
      )
    }
  }

}
