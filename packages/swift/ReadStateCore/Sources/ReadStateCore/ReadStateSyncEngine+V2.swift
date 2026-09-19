import Foundation

extension ReadStateSyncEngine {
  /// Initial migration remains v1. This separate step requires server-confirmed PDS authority.
  public func upgradeToV2() async throws {
    guard !flushing, transport.putV2Chunk != nil else { throw ReadStateSyncFailure.conflict }
    flushing = true; defer { flushing = false }
    guard let current = try await transport.readManifest() else { throw ReadStateError.incompleteGeneration }
    if current.manifest.version == 1 && !outbox.jobs.isEmpty { throw ReadStateSyncFailure.conflict }
    try await transport.confirm(current.cid, nil)
    let projection = try await transport.loadProjection(current.manifest)
    if current.manifest.version == 1 && !outbox.jobs.isEmpty { throw ReadStateSyncFailure.conflict }
    try initializeV2(projection: projection)
    if current.manifest.version == 1 { try await maintainV2(current: current, projection: projection) }
    else { outbox.v2?.maintenance = nil; try persist() }
  }

  /// Explicit semantic compaction; no record deletion occurs here.
  public func compactV2() async throws {
    guard !flushing, outbox.jobs.isEmpty, transport.putV2Chunk != nil else { throw ReadStateSyncFailure.conflict }
    flushing = true; defer { flushing = false }
    guard let current = try await transport.readManifest(), current.manifest.version == 2 else { throw ReadStateError.incompleteGeneration }
    try await transport.confirm(current.cid, nil)
    let projection = try await transport.loadProjection(current.manifest)
    try initializeV2(projection: projection)
    try await maintainV2(current: current, projection: projection)
  }

  private func initializeV2(projection: ReadStateProjection) throws {
    let previous = outbox
    do {
      if outbox.v2 == nil { outbox.v2 = try ReadStateOutboxV2State(viewerDid: viewerDid) }
      let receipts = Dictionary(uniqueKeysWithValues: projection.legacyReceipts.map { ($0.actionId, $0) })
      // The caller has confirmed this complete generation before retiring old baseline work.
      if projection.protocolVersion == 2 { outbox.jobs.removeAll { $0.expectedLegacyRevision != nil } }
      for index in outbox.jobs.indices where outbox.jobs[index].v2Actions == nil {
        var actions: [ReadStateOutboxV2State.Action] = []
        var committed = Set<String>()
        for parts in ReadStateV2PublicationBuilder.actionGroups(outbox.jobs[index].operations) {
          let hash = try ReadStateV2PublicationBuilder.hash(parts)
          if let receipt = receipts[parts[0].actionId] {
            guard receipt.originalIntentHash == hash else { throw ReadStateError.conflictingSequence }
            committed.insert(receipt.actionId); continue
          }
          guard outbox.v2!.nextCounter <= ReadStateValidation.maximumSequence else { throw ReadStateError.sizeLimit }
          actions.append(.init(actionId: parts[0].actionId, counter: outbox.v2!.nextCounter, intentHash: hash))
          outbox.v2!.nextCounter += 1
        }
        outbox.jobs[index].operations.removeAll { committed.contains($0.actionId) }
        outbox.jobs[index].localOverlay?.removeAll { committed.contains($0.actionId) }
        outbox.jobs[index].publication = nil; outbox.jobs[index].v2Actions = actions
      }
      outbox.jobs.removeAll { $0.operations.isEmpty }
      try persist()
    } catch { outbox = previous; throw error }
  }

  func enqueueV2(_ operations: [ReadStateOperation], localOverlay: [ReadStateOperation]?) throws {
    for op in operations + (localOverlay ?? []) { try ReadStateValidation.validate(op) }
    let previous = outbox
    do {
      let groups = ReadStateV2PublicationBuilder.actionGroups(operations)
      if groups.count == 1, operations.count == 1, operations[0].subjectUris?.count == 1,
        let last = outbox.jobs.last, last.v2Publication == nil, last.publication == nil,
        last.v2Actions?.count == 1, last.operations.count == 1,
        last.operations[0].subjectUris == operations[0].subjectUris {
        outbox.jobs[outbox.jobs.count - 1].operations = operations
        outbox.jobs[outbox.jobs.count - 1].localOverlay = localOverlay
        outbox.jobs[outbox.jobs.count - 1].v2Actions = [.init(actionId: operations[0].actionId,
          counter: last.v2Actions![0].counter, intentHash: try ReadStateV2PublicationBuilder.hash(operations))]
      } else {
        var actions: [ReadStateOutboxV2State.Action] = []
        for parts in groups {
          guard outbox.v2!.nextCounter <= ReadStateValidation.maximumSequence else { throw ReadStateError.sizeLimit }
          actions.append(.init(actionId: parts[0].actionId, counter: outbox.v2!.nextCounter,
            intentHash: try ReadStateV2PublicationBuilder.hash(parts)))
          outbox.v2!.nextCounter += 1
        }
        outbox.jobs.append(.init(id: UUID().uuidString.lowercased(), operations: operations,
          expectedLegacyRevision: nil, publication: nil, localOverlay: localOverlay, v2Actions: actions))
      }
      try persist()
    } catch { outbox = previous; throw error }
  }

  func flushV2(current: ReadStateManifestRecord) async throws {
    guard transport.putV2Chunk != nil else { throw ReadStateSyncFailure.conflict }
    let projection = try await transport.loadProjection(current.manifest)
    if outbox.v2 == nil || outbox.jobs.contains(where: { $0.v2Actions == nil }) {
      try await transport.confirm(current.cid, nil)
      try initializeV2(projection: projection)
    }
    if current.manifest.version == 1 {
      guard outbox.v2?.acknowledged.committedCounter == 0 else { throw ReadStateError.incompleteGeneration }
      try await transport.confirm(current.cid, nil)
      try await maintainV2(current: current, projection: projection)
      return
    }
    if outbox.v2?.maintenance != nil {
      try await transport.confirm(current.cid, nil)
      outbox.v2?.maintenance = nil; try persist()
    }
    guard let local = outbox.v2?.acknowledged else { throw ReadStateSyncFailure.corruptOutbox }
    let emptyReceipt = try ReadStateDeviceReceipt(viewerDid: viewerDid, deviceId: local.deviceId)
    let remote = projection.deviceReceipts.first { $0.deviceId == local.deviceId } ?? emptyReceipt
    let pending = outbox.jobs.flatMap { $0.v2Actions ?? [] }
    guard pending.enumerated().allSatisfy({ $0.element.counter == local.committedCounter + 1 + Int64($0.offset) }) else { throw ReadStateSyncFailure.corruptOutbox }
    let acknowledgedCount = try local.verifiedAcknowledgement(remote, pendingIntentHashes: pending.map(\.intentHash))
    if acknowledgedCount > 0 {
      try await transport.confirm(current.cid, nil)
      let ids = Set(pending.prefix(acknowledgedCount).map(\.actionId))
      for index in outbox.jobs.indices {
        outbox.jobs[index].operations.removeAll { ids.contains($0.actionId) }
        outbox.jobs[index].localOverlay?.removeAll { ids.contains($0.actionId) }
        outbox.jobs[index].v2Actions?.removeAll { ids.contains($0.actionId) }
        outbox.jobs[index].v2Publication = nil
      }
      outbox.jobs.removeAll { $0.operations.isEmpty }
      outbox.v2?.acknowledged = remote
      try persist(); return
    }
    guard let job = outbox.jobs.first else { return }
    guard let actions = job.v2Actions, !actions.isEmpty else { throw ReadStateSyncFailure.corruptOutbox }
    if job.v2Publication?.baseCid != current.cid {
      outbox.jobs[0].v2Publication = try ReadStateV2PublicationBuilder.publication(current: current,
        projection: projection, viewerDid: viewerDid, operations: job.operations, actions: actions, device: local)
      try persist()
    }
    try await uploadV2(maintenance: false)
    // A subsequent iteration verifies the current device prefix before dropping pending work.
  }

  private func maintainV2(current: ReadStateManifestRecord, projection: ReadStateProjection) async throws {
    guard let device = outbox.v2?.acknowledged else { throw ReadStateSyncFailure.corruptOutbox }
    if outbox.v2?.maintenance?.baseCid != current.cid {
      outbox.v2?.maintenance = current.manifest.version == 1
        ? try ReadStateV2PublicationBuilder.upgrade(current: current, projection: projection, viewerDid: viewerDid, device: device)
        : try ReadStateV2PublicationBuilder.publication(current: current, projection: projection, viewerDid: viewerDid, device: device, maintenance: true)
      try persist()
    }
    try await uploadV2(maintenance: true)
    outbox.v2?.maintenance = nil; try persist()
  }

  private func uploadV2(maintenance: Bool) async throws {
    guard let putChunk = transport.putV2Chunk else { throw ReadStateSyncFailure.conflict }
    func publication() throws -> ReadStateV2Publication {
      guard let value = maintenance ? outbox.v2?.maintenance : outbox.jobs.first?.v2Publication else { throw ReadStateSyncFailure.corruptOutbox }
      return value
    }
    func save(_ value: ReadStateV2Publication) throws {
      if maintenance { outbox.v2?.maintenance = value } else { outbox.jobs[0].v2Publication = value }
      try persist()
    }
    var value = try publication()
    if let cid = value.committedCid { try await transport.confirm(cid, nil); return }
    for index in value.chunks.indices {
      try Task.checkCancellation()
      if value.chunks[index].reference != nil { continue }
      let head: ReadStateReference?
      switch value.chunks[index].record.kind {
      case .state: head = value.stateHead
      case .devices: head = value.devicesHead
      case .legacyReceipts: head = value.legacyReceiptsHead
      }
      let record = value.chunks[index].record.replacingPrevious(head)
      value.chunks[index].record = record; try save(value)
      let reference = try await putChunk(value.chunks[index].key, record)
      try ReadStateValidation.validate(reference, viewerDid: viewerDid)
      value.chunks[index].reference = reference
      switch record.kind { case .state: value.stateHead = reference
      case .devices: value.devicesHead = reference
      case .legacyReceipts: value.legacyReceiptsHead = reference }
      try save(value)
    }
    try ReadStateValidation.validate(value.manifest, viewerDid: viewerDid)
    let cid = try await transport.putManifest(value.manifest, value.baseCid)
    value.committedCid = cid; try save(value)
    try await transport.confirm(cid, nil)
  }
}
