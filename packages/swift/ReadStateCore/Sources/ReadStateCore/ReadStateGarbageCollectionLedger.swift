import Foundation

struct ReadStateGarbageCollectionLedger: Codable, Sendable {
  struct Observation: Codable, Sendable {
    let reference: ReadStateReference
    var firstObservedAt: Date
    var firstObservedUptime: TimeInterval
  }
  struct Clock: Codable, Sendable {
    let wallTime: Date
    let uptime: TimeInterval
  }
  let viewerDid: String
  var observations: [String: Observation] = [:]
  var cursor: String?
  var clock: Clock?
  var pending: ReadStateGarbageCollectionBatch?
}
