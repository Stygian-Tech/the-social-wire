import Foundation
import OperationsCore

struct JetstreamReconnectProgressGate: Equatable, Sendable {
  let baselineReceivedCursor: Int64?
  let baselineCommittedCursor: Int64?
  private(set) var connectedAt: Date?

  init(state: IngestionStreamState?) {
    baselineReceivedCursor = state?.lastReceivedCursor
    baselineCommittedCursor = state?.lastCommittedCursor
    connectedAt = nil
  }

  mutating func beginConnectionAttempt() {
    connectedAt = nil
  }

  mutating func didConnect(at: Date) {
    connectedAt = at
  }

  func permitsCompletion(
    receivedCursor: Int64?,
    committedCursor: Int64?
  ) -> Bool {
    guard connectedAt != nil,
      let receivedCursor,
      let committedCursor
    else { return false }

    let receivedAdvanced = baselineReceivedCursor.map { receivedCursor > $0 } ?? true
    let committedAdvanced = baselineCommittedCursor.map { committedCursor > $0 } ?? true
    return receivedAdvanced && committedAdvanced
  }
}
