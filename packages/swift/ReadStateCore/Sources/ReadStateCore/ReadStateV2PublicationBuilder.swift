import Foundation

/// Pure bounded publication planning; only the caller's final CAS exposes these records.
enum ReadStateV2PublicationBuilder {
  static func hash(_ operations: [ReadStateOperation]) throws -> String {
    try ReadStateSemanticCompactor.originalIntentHash(partsJSON: JSONEncoder().encode(operations))
  }
  static func actionGroups(_ operations: [ReadStateOperation]) -> [[ReadStateOperation]] {
    var order: [String] = []; var groups: [String: [ReadStateOperation]] = [:]
    for operation in operations {
      if groups[operation.actionId] == nil { order.append(operation.actionId) }
      groups[operation.actionId, default: []].append(operation)
    }
    return order.map { groups[$0]! }
  }
  private static func compacted(_ fragments: [ReadStateV2Fragment], lastSequence: Int64,
    viewerDid: String) throws -> [ReadStateV2Fragment] {
    let manifest = ReadStateManifest(generation: "selector", lastSequence: lastSequence,
      head: fragments.isEmpty ? nil : .init(uri: "at://\(viewerDid)/\(ReadStateChunk.collection)/selector", cid: "selector"))
    let projection = try ReadStateProjection(operations: fragments.map(\.operation), lastSequence: lastSequence, protocolVersion: 2)
    let result = try ReadStateSemanticCompactor.compact(projection, manifestJSON: JSONEncoder().encode(manifest), viewerDid: viewerDid)
    let metadata = Dictionary(grouping: fragments, by: { $0.operation.actionId })
    return try result.operations.map { operation in
      let original = metadata[operation.actionId]![0]
      return try .init(operation: operation, intentHash: original.intentHash, deviceId: original.deviceId, deviceCounter: original.deviceCounter)
    }
  }
  private static func split(_ fragment: ReadStateV2Fragment, reserve: ReadStateReference,
    viewerDid: String) throws -> [ReadStateV2Fragment] {
    if try ReadStateValidation.encodedByteCount(ReadStateV2Chunk(fragments: [fragment], previous: reserve)) <= ReadStateValidation.maximumRecordBytes {
      return [fragment]
    }
    let value = fragment.operation
    let count = value.subjectUris?.count ?? value.boundaries?.count ?? 0
    guard count > 1 else { throw ReadStateError.sizeLimit }
    let middle = count / 2
    let operations: [ReadStateOperation]
    if let subjects = value.subjectUris {
      operations = [Array(subjects[..<middle]), Array(subjects[middle...])].map {
        .init(actionId: value.actionId, sequence: value.sequence, state: value.state, actedAt: value.actedAt, subjectUris: $0, calendar: value.calendar)
      }
    } else {
      let boundaries = value.boundaries ?? []
      operations = [Array(boundaries[..<middle]), Array(boundaries[middle...])].map {
        .init(actionId: value.actionId, sequence: value.sequence, state: value.state, actedAt: value.actedAt, boundaries: $0)
      }
    }
    return try operations.flatMap {
      try split(.init(operation: $0, intentHash: fragment.intentHash, deviceId: fragment.deviceId,
        deviceCounter: fragment.deviceCounter), reserve: reserve, viewerDid: viewerDid)
    }
  }
  private static func reservedReference(viewerDid: String) -> ReadStateReference {
    .init(uri: "at://\(viewerDid)/\(ReadStateChunk.collection)/" + String(repeating: "a", count: 512), cid: String(repeating: "b", count: 256))
  }
  private static func chunks(_ records: [ReadStateV2Chunk], viewerDid: String) throws -> [ReadStateV2Publication.Chunk] {
    let reserve = reservedReference(viewerDid: viewerDid)
    var packed: [ReadStateV2Chunk] = []
    for record in records {
      switch record.kind {
      case .state:
        var buffer: [ReadStateV2Fragment] = []
        for value in try record.fragments.flatMap({ try split($0, reserve: reserve, viewerDid: viewerDid) }) {
          let candidate = ReadStateV2Chunk(fragments: buffer + [value], previous: reserve)
          let byteCount = try ReadStateValidation.encodedByteCount(candidate)
          if buffer.count == 128 || byteCount > ReadStateValidation.maximumRecordBytes {
            if !buffer.isEmpty { packed.append(.init(fragments: buffer)); buffer = [] }
          }
          try ReadStateV2Chunk(fragments: [value], previous: reserve).validate(viewerDid: viewerDid)
          buffer.append(value)
        }
        if !buffer.isEmpty { packed.append(.init(fragments: buffer)) }
      case .devices:
        for start in stride(from: 0, to: record.deviceReceipts.count, by: 128) {
          packed.append(.init(devices: Array(record.deviceReceipts[start..<min(start + 128, record.deviceReceipts.count)])))
        }
      case .legacyReceipts:
        for start in stride(from: 0, to: record.legacyReceipts.count, by: 128) {
          packed.append(.init(legacyReceipts: Array(record.legacyReceipts[start..<min(start + 128, record.legacyReceipts.count)])))
        }
      }
    }
    var bytes = 0
    for chunk in packed {
      let reserved = chunk.replacingPrevious(reserve)
      try reserved.validate(viewerDid: viewerDid); bytes += try ReadStateValidation.encodedByteCount(reserved)
    }
    guard packed.count <= 4096, bytes <= 16 * 1024 * 1024 else { throw ReadStateError.sizeLimit }
    return packed.map { .init(key: UUID().uuidString.lowercased(), record: $0, reference: nil) }
  }
  static func upgrade(current: ReadStateManifestRecord, projection: ReadStateProjection,
    viewerDid: String, device: ReadStateDeviceReceipt) throws -> ReadStateV2Publication {
    guard current.manifest.version == 1, projection.protocolVersion == 1 else { throw ReadStateError.invalidRecord }
    let compact = try ReadStateSemanticCompactor.compact(projection,
      manifestJSON: JSONEncoder().encode(current.manifest), viewerDid: viewerDid)
    let receipts = Dictionary(uniqueKeysWithValues: compact.receipts.map { ($0.actionId, $0) })
    let fragments = try compact.operations.map { try ReadStateV2Fragment(operation: $0, intentHash: receipts[$0.actionId]!.originalIntentHash) }
    guard current.manifest.lastSequence < ReadStateValidation.maximumSequence else { throw ReadStateError.sizeLimit }
    return .init(baseCid: current.cid, generation: UUID().uuidString.lowercased(), revision: current.manifest.lastSequence + 1,
      lastSequence: current.manifest.lastSequence,
      chunks: try chunks([.init(fragments: fragments), .init(devices: [device]), .init(legacyReceipts: compact.receipts)], viewerDid: viewerDid),
      stateHead: nil, devicesHead: nil, legacyReceiptsHead: nil, committedCid: nil)
  }
  static func publication(current: ReadStateManifestRecord, projection: ReadStateProjection, viewerDid: String,
    operations: [ReadStateOperation] = [], actions: [ReadStateOutboxV2State.Action] = [], device: ReadStateDeviceReceipt,
    maintenance: Bool = false) throws -> ReadStateV2Publication {
    guard current.manifest.version == 2, projection.protocolVersion == 2,
      current.manifest.effectiveRevision < ReadStateValidation.maximumSequence else { throw ReadStateError.invalidRecord }
    var sequence = current.manifest.lastSequence
    var added: [ReadStateV2Fragment] = []
    let groups = Dictionary(grouping: operations, by: \.actionId)
    let legacy = Dictionary(uniqueKeysWithValues: projection.legacyReceipts.map { ($0.actionId, $0) })
    for action in actions {
      guard let parts = groups[action.actionId], try hash(parts) == action.intentHash else { throw ReadStateError.conflictingSequence }
      if let receipt = legacy[action.actionId] {
        guard receipt.originalIntentHash == action.intentHash else { throw ReadStateError.conflictingSequence }
        continue // Receipt-only acknowledgement of an already committed v1 intent.
      }
      guard sequence < ReadStateValidation.maximumSequence else { throw ReadStateError.sizeLimit }
      sequence += 1
      for value in parts {
        let operation: ReadStateOperation
        if let subjects = value.subjectUris {
          operation = .init(actionId: value.actionId, sequence: sequence, state: value.state, actedAt: value.actedAt, subjectUris: subjects, calendar: value.calendar)
        } else {
          operation = .init(actionId: value.actionId, sequence: sequence, state: value.state, actedAt: value.actedAt, boundaries: value.boundaries ?? [])
        }
        added.append(try .init(operation: operation, intentHash: action.intentHash,
          deviceId: device.deviceId, deviceCounter: action.counter))
      }
    }
    // Bound active chain depth without running the semantic analysis for every tap.
    let repack = maintenance || (projection.sourceChunksByKind["state"] ?? 0) >= 64
    let selected = repack ? try compacted(projection.v2Fragments + added, lastSequence: sequence, viewerDid: viewerDid) : added
    var devices = projection.deviceReceipts
    if !actions.isEmpty {
      let advanced = try device.advancing(firstCounter: actions[0].counter, intentHashes: actions.map(\.intentHash))
      guard zip(actions, actions.dropFirst()).allSatisfy({ $0.counter + 1 == $1.counter }) else { throw ReadStateError.conflictingSequence }
      devices.removeAll { $0.deviceId == device.deviceId }; devices.append(advanced)
    }
    devices.sort { $0.deviceId < $1.deviceId }
    let records: [ReadStateV2Chunk] = [.init(fragments: selected)] + (actions.isEmpty ? [] : [.init(devices: devices)])
    let uploads = try chunks(records, viewerDid: viewerDid)
    // Only roots retained by this CAS count; replaced state and device roots are unreachable.
    let reserve = reservedReference(viewerDid: viewerDid)
    let uploadedBytes = try uploads.reduce(0) { try $0 + ReadStateValidation.encodedByteCount($1.record.replacingPrevious(reserve)) }
    let retainedKinds = ["legacyReceipts"] + (repack ? [] : ["state"]) + (actions.isEmpty ? ["devices"] : [])
    let retainedChunks = retainedKinds.reduce(0) { $0 + (projection.sourceChunksByKind[$1] ?? 0) }
    let retainedBytes = retainedKinds.reduce(0) { $0 + (projection.sourceBytesByKind[$1] ?? 0) }
    guard uploads.count + retainedChunks <= 4096,
      uploadedBytes + retainedBytes <= 16 * 1024 * 1024 else { throw ReadStateError.sizeLimit }
    return .init(baseCid: current.cid, generation: UUID().uuidString.lowercased(), revision: current.manifest.effectiveRevision + 1,
      lastSequence: sequence, chunks: uploads, stateHead: repack ? nil : current.manifest.stateHead,
      devicesHead: actions.isEmpty ? current.manifest.devicesHead : nil, legacyReceiptsHead: current.manifest.legacyReceiptsHead,
      committedCid: nil)
  }
}
