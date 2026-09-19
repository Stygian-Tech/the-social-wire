import Foundation

extension ReadStateGenerationLoader {
  /// The callback binds the raw record to the viewer URI and verifies its CID.
  /// Both versions retain full-chain completeness and bounded raw-byte accounting.
  public static func loadRecords(manifest: ReadStateManifest, viewerDid: String,
    maximumChunks: Int = 4096, maximumBytes: Int = 16 * 1024 * 1024,
    fetchVerifiedRecord: @Sendable (ReadStateReference) async throws -> Data
  ) async throws -> ReadStateProjection {
    try ReadStateValidation.validate(manifest, viewerDid: viewerDid)
    if manifest.version == 1 {
      return try await load(manifest: manifest, viewerDid: viewerDid, maximumChunks: maximumChunks, maximumBytes: maximumBytes) { reference in
        let data = try await fetchVerifiedRecord(reference)
        guard data.count <= ReadStateValidation.maximumRecordBytes else { throw ReadStateError.sizeLimit }
        return try JSONDecoder().decode(ReadStateChunk.self, from: data)
      }
    }
    var visited = Set<ReadStateReference>()
    var fragments: [ReadStateV2Fragment] = []
    var devices: [ReadStateDeviceReceipt] = []
    var legacy: [ReadStateLegacyActionReceipt] = []
    var bytes = 0
    var bytesByKind: [String: Int] = [:]; var chunksByKind: [String: Int] = [:]
    let roots: [(ReadStateV2Chunk.Kind, ReadStateReference?)] = [(.state, manifest.stateHead), (.devices, manifest.devicesHead), (.legacyReceipts, manifest.legacyReceiptsHead)]
    for (kind, root) in roots {
      var reference = root
      while let current = reference {
        try Task.checkCancellation()
        try ReadStateValidation.validate(current, viewerDid: viewerDid)
        guard visited.insert(current).inserted else { throw ReadStateError.invalidReference }
        guard visited.count <= maximumChunks else { throw ReadStateError.sizeLimit }
        let data = try await fetchVerifiedRecord(current)
        bytes += data.count
        bytesByKind[kind.rawValue, default: 0] += data.count
        chunksByKind[kind.rawValue, default: 0] += 1
        guard data.count <= ReadStateValidation.maximumRecordBytes, bytes <= maximumBytes else { throw ReadStateError.sizeLimit }
        let chunk = try JSONDecoder().decode(ReadStateV2Chunk.self, from: data)
        try chunk.validate(viewerDid: viewerDid)
        guard chunk.kind == kind else { throw ReadStateError.invalidRecord }
        fragments += chunk.fragments; devices += chunk.deviceReceipts; legacy += chunk.legacyReceipts
        reference = chunk.previous
      }
    }
    guard Set(devices.map(\.deviceId)).count == devices.count,
      Set(legacy.map(\.actionId)).count == legacy.count,
      Set(legacy.map(\.originalSequence)).count == legacy.count else { throw ReadStateError.conflictingSequence }
    for receipt in devices where receipt.committedCounter == 0 {
      guard receipt == (try ReadStateDeviceReceipt(viewerDid: viewerDid, deviceId: receipt.deviceId)) else { throw ReadStateError.conflictingSequence }
    }
    let legacySequence = legacy.map(\.originalSequence).max() ?? 0
    let devicesById = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceId, $0) })
    let legacyById = Dictionary(uniqueKeysWithValues: legacy.map { ($0.actionId, $0) })
    var identityByAction: [String: ReadStateV2Fragment] = [:]
    var actionByCounter: [String: String] = [:]
    for fragment in fragments {
      let operation = fragment.operation
      if let previous = identityByAction[operation.actionId] {
        guard previous.intentHash == fragment.intentHash, previous.deviceId == fragment.deviceId,
          previous.deviceCounter == fragment.deviceCounter, previous.operation.selection == operation.selection else { throw ReadStateError.conflictingSequence }
      }
      identityByAction[operation.actionId] = fragment
      if let deviceId = fragment.deviceId, let counter = fragment.deviceCounter {
        guard let receipt = devicesById[deviceId], counter <= receipt.committedCounter, operation.sequence > legacySequence,
          legacyById[operation.actionId] == nil else { throw ReadStateError.incompleteGeneration }
        let key = "\(deviceId):\(counter)"
        guard actionByCounter[key] == nil || actionByCounter[key] == operation.actionId else { throw ReadStateError.conflictingSequence }
        actionByCounter[key] = operation.actionId
      } else {
        guard let receipt = legacyById[operation.actionId], receipt.originalSequence == operation.sequence,
          receipt.originalIntentHash == fragment.intentHash else { throw ReadStateError.incompleteGeneration }
      }
    }
    guard legacy.allSatisfy({ $0.originalSequence <= manifest.lastSequence }) else { throw ReadStateError.invalidRecord }
    return try ReadStateProjection(operations: fragments.map(\.operation), lastSequence: manifest.lastSequence,
      sourceChunkCount: visited.count, sourceBytes: bytes, sourceReferences: visited, protocolVersion: 2,
      v2Fragments: fragments, deviceReceipts: devices, legacyReceipts: legacy,
      sourceBytesByKind: bytesByKind, sourceChunksByKind: chunksByKind)
  }
}
