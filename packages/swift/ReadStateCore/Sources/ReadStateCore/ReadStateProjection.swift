import Foundation

/// Immutable projection installed only after the complete referenced chain has verified.
public struct ReadStateProjection: Sendable {
  private let exact: [String: ReadStateOperation]
  private let scoped: [String: [(ReadStateBoundary, Date, ReadStateOperation)]]
  public let lastSequence: Int64
  public let actionIds: Set<String>
  public let operations: [ReadStateOperation]
  public let sourceChunkCount: Int
  public let sourceBytesByKind: [String: Int]
  public let sourceChunksByKind: [String: Int]
  public let sourceBytes: Int
  public let allowsRepacking: Bool
  public let sourceReferences: Set<ReadStateReference>
  public let protocolVersion: Int
  public let v2Fragments: [ReadStateV2Fragment]
  public let deviceReceipts: [ReadStateDeviceReceipt]
  public let legacyReceipts: [ReadStateLegacyActionReceipt]

  public init(operations: [ReadStateOperation], lastSequence: Int64,
              sourceChunkCount: Int = 0, sourceBytes: Int = 0, allowsRepacking: Bool = true,
              sourceReferences: Set<ReadStateReference> = [], protocolVersion: Int = 1,
              v2Fragments: [ReadStateV2Fragment] = [], deviceReceipts: [ReadStateDeviceReceipt] = [],
              legacyReceipts: [ReadStateLegacyActionReceipt] = [],
              sourceBytesByKind: [String: Int] = [:], sourceChunksByKind: [String: Int] = [:]) throws {
    guard (0...ReadStateValidation.maximumSequence).contains(lastSequence) else {
      throw ReadStateError.invalidRecord
    }
    var exact: [String: ReadStateOperation] = [:]
    var scoped: [String: [(ReadStateBoundary, Date, ReadStateOperation)]] = [:]
    var sequences: [Int64: ReadStateOperation] = [:]
    var actions: [String: Int64] = [:]
    for operation in operations {
      try ReadStateValidation.validate(operation)
      guard operation.sequence <= lastSequence else { throw ReadStateError.invalidRecord }
      if let other = sequences[operation.sequence],
         (other.actionId != operation.actionId || other.state != operation.state
           || other.actedAt != operation.actedAt || other.calendar != operation.calendar) {
        throw ReadStateError.conflictingSequence
      }
      if let sequence = actions[operation.actionId], sequence != operation.sequence {
        throw ReadStateError.conflictingSequence
      }
      sequences[operation.sequence] = operation
      actions[operation.actionId] = operation.sequence
      for uri in operation.subjectUris ?? [] where (exact[uri]?.sequence ?? 0) < operation.sequence {
        exact[uri] = operation
      }
      for boundary in operation.boundaries ?? [] {
        scoped[boundary.scope.authorDid, default: []].append(
          (boundary, try ReadStateValidation.date(boundary.createdAt), operation))
      }
    }
    guard [1, 2].contains(protocolVersion), protocolVersion == 2 || operations.map(\.sequence).max() ?? 0 == lastSequence else { throw ReadStateError.incompleteGeneration }
    self.exact = exact
    self.scoped = scoped
    self.lastSequence = lastSequence
    actionIds = Set(actions.keys)
    self.operations = operations
    self.sourceChunkCount = sourceChunkCount
    self.sourceBytes = sourceBytes
    self.sourceBytesByKind = sourceBytesByKind; self.sourceChunksByKind = sourceChunksByKind
    self.allowsRepacking = allowsRepacking
    self.sourceReferences = sourceReferences
    self.protocolVersion = protocolVersion; self.v2Fragments = v2Fragments
    self.deviceReceipts = deviceReceipts; self.legacyReceipts = legacyReceipts
  }

  public func resolve(_ subject: ReadStateSubject) -> ReadStateResolution {
    var latest = exact[subject.uri]
    for (boundary, date, operation) in scoped[subject.authorDid] ?? [] {
      guard operation.sequence > (latest?.sequence ?? 0) else { continue }
      let keys = boundary.scope.publicationSiteKeys
      guard keys.isEmpty || subject.publicationSite.map(keys.contains) == true else { continue }
      guard subject.createdAt < date || (subject.createdAt == date
        && (boundary.entryId.map { !($0.utf8.lexicographicallyPrecedes(subject.uri.utf8)) } ?? true)) else {
        continue
      }
      latest = operation
    }
    return ReadStateResolution(isRead: latest?.state == .read,
      readAt: latest?.state == .read ? latest?.actedAt : nil,
      sequence: latest?.sequence ?? 0, actionId: latest?.actionId)
  }
}
