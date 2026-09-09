import Foundation

/// Opt-in, bounded collector. The abstract proof transport is intentionally
/// unavailable by default until an audited repo-proof verifier is installed.
public actor ReadStateGarbageCollectionEngine {
  public enum Outcome: Sendable, Equatable {
    case disabled, busy, observed(Int), collected(Int), recheckRequired
  }
  public enum Failure: Error, Sendable, Equatable { case proofUnavailable, changedSnapshot }
  public static let minimumGrace: TimeInterval = 24 * 60 * 60
  private let viewerDid: String
  private let enabled: Bool
  private let transport: ReadStateGarbageCollectionTransport?
  private let storage: ReadStateOwnedFileStorage<ReadStateGarbageCollectionLedger>
  private var ledger: ReadStateGarbageCollectionLedger
  private var running = false

  public init(viewerDid: String, file: URL, enabled: Bool = false,
    transport: ReadStateGarbageCollectionTransport? = nil) throws {
    self.viewerDid = viewerDid; self.enabled = enabled; self.transport = transport
    storage = .init(file: file)
    ledger = try storage.claim(initial: .init(viewerDid: viewerDid)) { $0.viewerDid == viewerDid }
  }

  /// Uptime detects wall-clock jumps. Restart on the same boot preserves grace;
  /// clock discontinuity conservatively restarts every observation's grace.
  /// Each proof transport call must have its own bounded network deadline.
  public func run(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) async throws -> Outcome {
    guard enabled else { return .disabled }
    guard !running else { return .busy }
    guard let transport else { throw Failure.proofUnavailable }
    running = true; defer { running = false }
    let started = ContinuousClock.now
    func checkBudget() throws {
      try Task.checkCancellation()
      guard started.duration(to: .now) < .seconds(30) else { throw URLError(.timedOut) }
    }
    guard let snapshot = try await transport.verifiedSnapshot() else { throw Failure.proofUnavailable }
    try checkBudget()
    try ReadStateGarbageCollectionPlanner.validate(snapshot, viewerDid: viewerDid)
    try await transport.confirmGeneration(snapshot.record.cid)
    try checkBudget()
    if let pending = ledger.pending {
      if snapshot.record.manifest == pending.manifest {
        for reference in pending.deletions { ledger.observations.removeValue(forKey: reference.uri) }
        ledger.pending = nil; try storage.write(ledger)
        return .collected(pending.deletions.count)
      }
      // Never resend a persisted delete plan. Even an unchanged old commit gets
      // a fresh proof and a new CAS candidate after an ambiguous response.
      ledger.pending = nil
    }
    guard now.timeIntervalSince1970.isFinite, uptime.isFinite, uptime >= 0 else { throw ReadStateError.invalidRecord }
    if let clock = ledger.clock {
      let wallDelta = now.timeIntervalSince(clock.wallTime), uptimeDelta = uptime - clock.uptime
      if wallDelta < 0 || uptimeDelta < 0 || abs(wallDelta - uptimeDelta) > 300 {
        for key in ledger.observations.keys {
          ledger.observations[key]?.firstObservedAt = now
          ledger.observations[key]?.firstObservedUptime = uptime
        }
      }
    }
    ledger.clock = .init(wallTime: now, uptime: uptime)
    let reachable = Set(snapshot.projection.sourceReferences.map(\.uri))
    for uri in reachable { ledger.observations.removeValue(forKey: uri) }
    let page = try await transport.listChunks(ledger.cursor, 128)
    try checkBudget()
    guard page.references.count <= 128, (page.cursor?.utf8.count ?? 0) <= 4096 else { throw ReadStateError.sizeLimit }
    for reference in page.references {
      try ReadStateValidation.validate(reference, viewerDid: viewerDid)
      guard !reachable.contains(reference.uri) else { continue }
      if let old = ledger.observations[reference.uri], old.reference == reference { continue }
      if ledger.observations.count < 4096 || ledger.observations[reference.uri] != nil {
        ledger.observations[reference.uri] = .init(reference: reference, firstObservedAt: now, firstObservedUptime: uptime)
      }
    }
    ledger.cursor = page.cursor
    try storage.write(ledger)
    let eligible = ledger.observations.values.filter {
      now.timeIntervalSince($0.firstObservedAt) >= Self.minimumGrace
        && uptime - $0.firstObservedUptime >= Self.minimumGrace && !reachable.contains($0.reference.uri)
    }.sorted {
      $0.firstObservedAt == $1.firstObservedAt ? $0.reference.uri < $1.reference.uri : $0.firstObservedAt < $1.firstObservedAt
    }.prefix(100)
    var deletions: [ReadStateReference] = []
    for observation in eligible {
      try checkBudget()
      let reference = observation.reference
      guard let proof = try await transport.verifiedChunk(reference, snapshot.repositoryCommitCid) else {
        ledger.observations.removeValue(forKey: reference.uri); continue
      }
      try checkBudget()
      guard proof.viewerDid == viewerDid, proof.repositoryCommitCid == snapshot.repositoryCommitCid else {
        throw Failure.changedSnapshot
      }
      guard proof.reference == reference else {
        ledger.observations.removeValue(forKey: reference.uri); continue
      }
      // Content hashes are checked independently of the repo membership proof.
      do {
        try ReadStateRecordCID.verify(json: proof.json, cid: reference.cid)
        let raw = try JSONDecoder().decode(ReadStateJSONValue.self, from: proof.json)
        guard case .object(let fields) = raw else { throw ReadStateError.invalidRecord }
        if fields["version"] == .integer(1) {
          let chunk = try JSONDecoder().decode(ReadStateChunk.self, from: proof.json)
          try ReadStateValidation.validate(chunk, viewerDid: viewerDid)
          guard chunk.allowsRepacking else { throw ReadStateError.invalidRecord }
        } else {
          let chunk = try JSONDecoder().decode(ReadStateV2Chunk.self, from: proof.json)
          try chunk.validate(viewerDid: viewerDid)
        }
      } catch {
        // Unknown or unreadable records are never deleted; reset their grace.
        ledger.observations.removeValue(forKey: reference.uri); continue
      }
      deletions.append(reference)
    }
    guard !deletions.isEmpty else { try storage.write(ledger); return .observed(ledger.observations.count) }
    let batch = try ReadStateGarbageCollectionPlanner.makeBatch(viewerDid: viewerDid, snapshot: snapshot, candidates: deletions)
    ledger.pending = batch; try storage.write(ledger)
    try checkBudget()
    let result = try await transport.applyAtomic(batch)
    // If either response is lost, the durable plan remains and a new run first
    // verifies the current manifest. No individual deletion retry is available.
    guard let confirmed = try await transport.verifiedSnapshot() else { throw Failure.proofUnavailable }
    try checkBudget()
    try ReadStateGarbageCollectionPlanner.validate(confirmed, viewerDid: viewerDid)
    guard confirmed.repositoryCommitCid == result.repositoryCommitCid,
      confirmed.record.cid == result.manifestCid, confirmed.record.manifest == batch.manifest else { return .recheckRequired }
    try await transport.confirmGeneration(confirmed.record.cid)
    try checkBudget()
    for reference in deletions { ledger.observations.removeValue(forKey: reference.uri) }
    ledger.pending = nil; try storage.write(ledger)
    return .collected(deletions.count)
  }
}
