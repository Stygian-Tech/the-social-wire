import Foundation

/// Serial, durable publication. A failed upload resumes the same immutable chunks;
/// only the final manifest makes an action visible to projections.
public actor ReadStateSyncEngine {
  let viewerDid: String
  let storage: ReadStateOutboxStorage
  let transport: ReadStateSyncTransport
  var outbox: ReadStateOutbox
  var flushing = false
  var cachedProjection: (cid: String, projection: ReadStateProjection)?

  public init(viewerDid: String, file: URL, transport: ReadStateSyncTransport) throws {
    self.viewerDid = viewerDid
    self.storage = ReadStateOutboxStorage(file: file)
    self.transport = transport
    outbox = try storage.claim(viewerDid: viewerDid)
  }

  public var pendingCount: Int { outbox.jobs.count }
  public var retryAfter: Date? { outbox.retryAfter }
  public var pendingLocalOperations: [ReadStateOperation] {
    outbox.jobs.filter { $0.expectedLegacyRevision == nil }.flatMap { $0.localOverlay ?? $0.operations }
  }

  /// Call only after the server confirms this viewer still has AppView authority.
  /// The exact manifest CID fences a competing migration or newly published action.
  public func replaceUnverifiedMigration(_ operations: [ReadStateOperation],
      legacyRevision: Int64, replacingManifestCid: String?) throws {
    guard !flushing, outbox.jobs.allSatisfy({ $0.expectedLegacyRevision != nil }) else {
      throw ReadStateSyncFailure.conflict
    }
    let previous = outbox
    outbox.jobs = []
    outbox.retryAfter = nil
    outbox.failures = 0
    do {
      try enqueue(operations, expectedLegacyRevision: legacyRevision)
      outbox.jobs[0].replacingManifestCid = replacingManifestCid
      try persist()
    } catch { outbox = previous; try? persist(); throw error }
  }

  /// A server-verified migration by another device supersedes local baseline work.
  public func discardVerifiedMigration() throws {
    guard outbox.jobs.contains(where: { $0.expectedLegacyRevision != nil }) else { return }
    guard !flushing else { throw ReadStateSyncFailure.conflict }
    outbox.jobs.removeAll { $0.expectedLegacyRevision != nil }
    try persist()
  }

  public func enqueue(_ operations: [ReadStateOperation], expectedLegacyRevision: Int64? = nil,
      localOverlay: [ReadStateOperation]? = nil) throws {
    guard !operations.isEmpty || expectedLegacyRevision != nil else { return }
    if outbox.v2 != nil {
      guard expectedLegacyRevision == nil else { throw ReadStateSyncFailure.conflict }
      try enqueueV2(operations, localOverlay: localOverlay)
      return
    }
    for operation in operations + (localOverlay ?? []) { try ReadStateValidation.validate(operation) }
    let previous = outbox
    // Coalesce only an unstarted individual intent. Never rewrite a published or
    // bulk action, nor move a new action across an intervening operation.
    if expectedLegacyRevision == nil, operations.count == 1,
       let operation = operations.first, operation.subjectUris?.count == 1,
       let last = outbox.jobs.last, last.publication == nil,
       last.expectedLegacyRevision == nil, last.operations.count == 1,
       last.operations.first?.subjectUris == operation.subjectUris {
      outbox.jobs[outbox.jobs.count - 1].operations = operations
      outbox.jobs[outbox.jobs.count - 1].localOverlay = localOverlay
    } else {
      outbox.jobs.append(.init(id: UUID().uuidString.lowercased(), operations: operations,
        expectedLegacyRevision: expectedLegacyRevision, publication: nil, localOverlay: localOverlay))
    }
    do { try persist() } catch { outbox = previous; throw error }
  }

  /// Does not sleep through throttling. The caller schedules a wake-up at retryAfter.
  public func flush(now: Date = Date()) async throws {
    guard !flushing, outbox.retryAfter.map({ $0 <= now }) ?? true else { return }
    flushing = true
    defer { flushing = false }
    do {
      while !outbox.jobs.isEmpty {
        try Task.checkCancellation()
        let jobId = outbox.jobs[0].id
        let current = try await transport.readManifest()
        if let current, current.manifest.version == 2 || outbox.v2 != nil {
          try await flushV2(current: current)
          continue
        }
        // Only a revision-fenced initial migration may create the singleton.
        // A missing manifest for an active viewer is a recovery failure, not empty history.
        if current == nil, outbox.jobs[0].expectedLegacyRevision == nil {
          throw ReadStateError.incompleteGeneration
        }
        if let publication = outbox.jobs[0].publication,
           let committed = publication.committedCid, current?.cid == committed {
          try await transport.confirm(committed, outbox.jobs[0].expectedLegacyRevision)
          outbox.jobs.removeFirst()
          try persist()
          continue
        }
        if let current {
          try ReadStateValidation.validate(current.manifest, viewerDid: viewerDid)
          let projection: ReadStateProjection
          if let cachedProjection, cachedProjection.cid == current.cid {
            projection = cachedProjection.projection
          } else {
            projection = try await transport.loadProjection(current.manifest)
            cachedProjection = (current.cid, projection)
          }
          let ids = Set(outbox.jobs[0].operations.map(\.actionId))
          if (!ids.isEmpty && ids.isSubset(of: projection.actionIds))
              || (ids.isEmpty && outbox.jobs[0].publication?.generation == current.manifest.generation) {
            try await transport.confirm(current.cid, outbox.jobs[0].expectedLegacyRevision)
            outbox.jobs.removeFirst()
            try persist()
            continue
          }
        }
        if outbox.jobs[0].publication == nil
            || outbox.jobs[0].publication?.baseCid != current?.cid {
          // A first migration must not overwrite state already committed by another device.
          if outbox.jobs[0].expectedLegacyRevision != nil
              && current?.cid != outbox.jobs[0].replacingManifestCid {
            throw ReadStateSyncFailure.conflict
          }
          outbox.jobs[0].publication = try publication(for: outbox.jobs[0], current: current,
            projection: cachedProjection?.cid == current?.cid ? cachedProjection?.projection : nil)
          try persist()
        }
        let count = outbox.jobs[0].publication!.chunks.count
        for index in 0..<count {
          try Task.checkCancellation()
          guard outbox.jobs[0].id == jobId else { throw ReadStateSyncFailure.corruptOutbox }
          var publication = outbox.jobs[0].publication!
          if publication.chunks[index].reference != nil { continue }
          let chunk = publication.chunks[index]
          let record = ReadStateChunk(operations: chunk.record.operations, previous: publication.head)
          publication.chunks[index].record = record
          outbox.jobs[0].publication = publication
          try persist()
          let reference = try await transport.putChunk(chunk.key, record)
          try ReadStateValidation.validate(reference, viewerDid: viewerDid)
          outbox.jobs[0].publication!.chunks[index].reference = reference
          outbox.jobs[0].publication!.head = reference
          try persist()
        }
        let publication = outbox.jobs[0].publication!
        let manifest = ReadStateManifest(generation: publication.generation,
          lastSequence: publication.lastSequence, head: publication.head,
          extensions: publication.manifestExtensions ?? [:])
        try ReadStateValidation.validate(manifest, viewerDid: viewerDid)
        let cid = try await transport.putManifest(manifest, publication.baseCid)
        outbox.jobs[0].publication!.committedCid = cid
        try persist()
        try await transport.confirm(cid, outbox.jobs[0].expectedLegacyRevision)
        outbox.jobs.removeFirst()
        outbox.failures = 0
        outbox.retryAfter = nil
        try persist()
      }
      // V2 receipt acknowledgments also finish a successful drain. Do not carry
      // an old outage's backoff into unrelated changes after recovery or restart.
      if outbox.failures != 0 || outbox.retryAfter != nil {
        outbox.failures = 0
        outbox.retryAfter = nil
        try persist()
      }
    } catch {
      outbox.failures = min(outbox.failures + 1, 10)
      if case ReadStateSyncFailure.rateLimited(let until) = error {
        outbox.retryAfter = max(until, now.addingTimeInterval(1))
      } else {
        let delay = min(300, pow(2, Double(outbox.failures))) + Double.random(in: 0...1)
        outbox.retryAfter = now.addingTimeInterval(delay)
      }
      try persist()
      throw error
    }
  }

  private func publication(for job: ReadStateOutbox.Job, current: ReadStateManifestRecord?,
      projection: ReadStateProjection?) throws -> ReadStateOutbox.Publication {
    let isMigration = job.expectedLegacyRevision != nil
    if current != nil, !isMigration, projection == nil { throw ReadStateError.incompleteGeneration }
    var sequence = isMigration ? 0 : (current?.manifest.lastSequence ?? 0)
    var sequences: [String: Int64] = [:]
    var operations: [ReadStateOperation] = []
    for value in job.operations {
      if !isMigration, projection?.actionIds.contains(value.actionId) == true { continue }
      if sequences[value.actionId] == nil {
        guard sequence < ReadStateValidation.maximumSequence else { throw ReadStateError.sizeLimit }
        sequence += 1
        sequences[value.actionId] = sequence
      }
      if let subjects = value.subjectUris {
        operations.append(.init(actionId: value.actionId, sequence: sequences[value.actionId]!, state: value.state,
          actedAt: value.actedAt, subjectUris: subjects, calendar: value.calendar))
      } else {
        operations.append(.init(actionId: value.actionId, sequence: sequences[value.actionId]!, state: value.state,
          actedAt: value.actedAt, boundaries: value.boundaries ?? []))
      }
    }
    var packed = try ReadStateDensePacking.chunks(operations: operations, viewerDid: viewerDid)
    var repacked = false
    if !isMigration, let projection, projection.allowsRepacking,
       projection.sourceChunkCount + packed.count > 64 {
      let dense = try ReadStateDensePacking.chunks(operations: projection.operations + operations, viewerDid: viewerDid)
      if projection.sourceChunkCount + packed.count > dense.count + 64 {
        packed = dense
        repacked = true
      }
    }
    try ReadStateDensePacking.validateGeneration(chunks: packed, viewerDid: viewerDid,
      existingChunkCount: isMigration || repacked ? 0 : projection?.sourceChunkCount ?? 0,
      existingBytes: isMigration || repacked ? 0 : projection?.sourceBytes ?? 0)
    let chunks = packed.map { ReadStateOutbox.Chunk(key: UUID().uuidString.lowercased(), record: $0, reference: nil) }
    return .init(baseCid: current?.cid, generation: job.id, chunks: chunks,
      head: isMigration || repacked ? nil : current?.manifest.head,
      lastSequence: sequence, committedCid: nil, manifestExtensions: current?.manifest.extensions)
  }

  func persist() throws {
    try storage.write(outbox)
  }
}
