import Foundation

/// Pure v2 foundation. The caller must supply a complete CID-verified source;
/// this type neither publishes records nor authorizes their deletion.
public enum ReadStateSemanticCompactor {
  private struct Rule {
    let operation: ReadStateOperation
    let boundary: ReadStateBoundary
    let scopeKey: String
    let key: String
  }
  private struct Selection {
    let operation: ReadStateOperation
    var subjects: [String] = []
    var boundaries: [ReadStateBoundary] = []
  }
  private static func sortedSet(_ values: [String]) -> [String] {
    Set(values).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }
  private static func canonical(_ boundary: ReadStateBoundary) -> ReadStateBoundary {
    .init(scope: .init(publicationId: boundary.scope.publicationId, authorDid: boundary.scope.authorDid,
      publicationSiteKeys: sortedSet(boundary.scope.publicationSiteKeys)), createdAt: boundary.createdAt, entryId: boundary.entryId)
  }
  private static func key<T: Encodable>(_ value: T) throws -> String {
    try ReadStateV2CanonicalHash.key(ReadStateV2CanonicalHash.value(value))
  }
  /// Accepts raw original parts so unknown fields cannot disappear during typed decoding.
  public static func originalIntentHash(partsJSON: Data) throws -> String {
    guard partsJSON.count <= 16 * 1024 * 1024,
      let values = try JSONSerialization.jsonObject(with: partsJSON) as? [[String: Any]] else { throw ReadStateError.invalidRecord }
    for value in values {
      let raw = try JSONSerialization.data(withJSONObject: ["$type": ReadStateChunk.collection, "version": 1, "operations": [value]])
      let chunk = try JSONDecoder().decode(ReadStateChunk.self, from: raw)
      guard chunk.allowsRepacking else { throw ReadStateError.invalidRecord }
    }
    return try intentHash(parts: JSONDecoder().decode([ReadStateOperation].self, from: partsJSON))
  }
  private static func intentHash(parts: [ReadStateOperation]) throws -> String {
    guard let first = parts.first else { throw ReadStateError.invalidRecord }
    for part in parts {
      try ReadStateValidation.validate(part)
      guard part.actionId == first.actionId, part.sequence == first.sequence, part.state == first.state,
        part.actedAt == first.actedAt, part.selection == first.selection, part.calendar == first.calendar else { throw ReadStateError.conflictingSequence }
    }
    var base: [String: ReadStateJSONValue] = ["actionId": .string(first.actionId), "state": .string(first.state.rawValue),
      "actedAt": .string(first.actedAt), "selection": .string(first.selection.rawValue)]
    if let calendar = first.calendar { base["calendar"] = try ReadStateV2CanonicalHash.value(calendar) }
    if first.selection == .exact {
      base["subjectUris"] = .array(sortedSet(parts.flatMap { $0.subjectUris ?? [] }).map(ReadStateJSONValue.string))
    } else {
      var boundaries: [String: ReadStateJSONValue] = [:]
      for boundary in parts.flatMap({ $0.boundaries ?? [] }).map(canonical) {
        boundaries[try key(boundary)] = try ReadStateV2CanonicalHash.value(boundary)
      }
      base["boundaries"] = .array(boundaries.keys.sorted().map { boundaries[$0]! })
    }
    return try ReadStateV2CanonicalHash.hash(.array([.string("app.thesocialwire.read-state/original-intent/v2"), .object(base)]))
  }
  private static func covers(_ upper: ReadStateBoundary, _ lower: ReadStateBoundary) throws -> Bool {
    let a = try ReadStateValidation.date(upper.createdAt), b = try ReadStateValidation.date(lower.createdAt)
    if a != b { return a > b }
    guard let left = upper.entryId else { return true }
    guard let right = lower.entryId else { return false }
    return !left.utf8.lexicographicallyPrecedes(right.utf8)
  }
  public static func compact(_ projection: ReadStateProjection, manifestJSON: Data,
    viewerDid: String) throws -> ReadStateCompactionResult {
    guard let raw = try JSONSerialization.jsonObject(with: manifestJSON) as? [String: Any],
      Set(raw.keys).isSubset(of: ["$type", "version", "generation", "lastSequence", "head"]) else { throw ReadStateError.invalidRecord }
    if let head = raw["head"] as? [String: Any], !Set(head.keys).isSubset(of: ["uri", "cid"]) { throw ReadStateError.invalidRecord }
    let manifest = try JSONDecoder().decode(ReadStateManifest.self, from: manifestJSON)
    try ReadStateValidation.validate(manifest, viewerDid: viewerDid)
    guard projection.allowsRepacking, manifest.extensions.isEmpty,
      projection.lastSequence == manifest.lastSequence else { throw ReadStateError.invalidRecord }
    let actions = Dictionary(grouping: projection.operations, by: \.actionId)
    var receipts: [ReadStateLegacyActionReceipt] = []
    var exact: [String: ReadStateOperation] = [:]
    var rules: [Rule] = []
    for parts in actions.values {
      let operation = parts[0]
      receipts.append(.init(actionId: operation.actionId, originalSequence: operation.sequence,
        originalIntentHash: try intentHash(parts: parts)))
      for part in parts {
        for uri in part.subjectUris ?? [] where (exact[uri]?.sequence ?? 0) < operation.sequence { exact[uri] = operation }
        for source in part.boundaries ?? [] {
          // PostgreSQL server boundaries have microsecond precision. Refuse finer
          // timestamps instead of proving domination using rounded Swift Dates.
          if let dot = source.createdAt.firstIndex(of: ".") {
            let fraction = source.createdAt[source.createdAt.index(after: dot)...].prefix { $0.isNumber }
            guard fraction.dropFirst(6).allSatisfy({ $0 == "0" }) else { throw ReadStateError.invalidRecord }
          }
          let boundary = canonical(source)
          rules.append(.init(operation: operation, boundary: boundary,
            scopeKey: try key(boundary.scope), key: try key(boundary)))
        }
      }
    }
    var selections: [String: Selection] = [:]
    for (uri, operation) in exact {
      var selection = selections[operation.actionId] ?? Selection(operation: operation)
      selection.subjects.append(uri); selections[operation.actionId] = selection
    }
    rules.sort { $0.operation.sequence == $1.operation.sequence ? $0.key < $1.key : $0.operation.sequence > $1.operation.sequence }
    var maxima: [String: ReadStateBoundary] = [:]
    var seen = Set<String>()
    var start = 0
    while start < rules.count {
      var end = start + 1
      while end < rules.count && rules[end].operation.sequence == rules[start].operation.sequence { end += 1 }
      for rule in rules[start..<end] {
        let dominated = try maxima[rule.scopeKey].map { try covers($0, rule.boundary) } ?? false
        if !dominated && seen.insert("\(rule.operation.sequence):\(rule.key)").inserted {
          var selection = selections[rule.operation.actionId] ?? Selection(operation: rule.operation)
          selection.boundaries.append(rule.boundary); selections[rule.operation.actionId] = selection
        }
      }
      for rule in rules[start..<end] {
        if try maxima[rule.scopeKey].map({ try !covers($0, rule.boundary) }) ?? true { maxima[rule.scopeKey] = rule.boundary }
      }
      start = end
    }
    var result: [ReadStateOperation] = []
    for selection in selections.values.sorted(by: { $0.operation.sequence < $1.operation.sequence }) {
      let op = selection.operation
      if op.selection == .exact {
        let values = sortedSet(selection.subjects)
        for start in stride(from: 0, to: values.count, by: 256) {
          result.append(.init(actionId: op.actionId, sequence: op.sequence, state: op.state, actedAt: op.actedAt,
            subjectUris: Array(values[start..<min(start + 256, values.count)]), calendar: op.calendar))
        }
      } else {
        let values = try selection.boundaries.map { (try key($0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        for start in stride(from: 0, to: values.count, by: 128) {
          result.append(.init(actionId: op.actionId, sequence: op.sequence, state: op.state, actedAt: op.actedAt,
            boundaries: Array(values[start..<min(start + 128, values.count)])))
        }
      }
    }
    return .init(operations: result, receipts: receipts.sorted { $0.originalSequence < $1.originalSequence })
  }
}
