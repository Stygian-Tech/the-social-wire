import Foundation

public enum ReadStateValidation {
  public static let maximumRecordBytes = 65_536
  public static let maximumSequence: Int64 = 9_007_199_254_740_991

  public static func date(_ value: String) throws -> Date {
    // ISO8601DateFormatter truncates fractional seconds on some Foundation
    // platforms. PostgreSQL boundaries retain microseconds, so parse the whole
    // second separately and add the fraction without moving URI tie boundaries.
    let pattern = #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"#
    let regex = try NSRegularExpression(pattern: pattern)
    let text = value as NSString
    guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: text.length)),
          let whole = ISO8601DateFormatter().date(from:
            text.substring(with: match.range(at: 1)) + text.substring(with: match.range(at: 3))) else {
      throw ReadStateError.invalidRecord
    }
    let fractionRange = match.range(at: 2)
    guard fractionRange.location != NSNotFound else { return whole }
    guard let fraction = Double("0." + text.substring(with: fractionRange)) else {
      throw ReadStateError.invalidRecord
    }
    return whole.addingTimeInterval(fraction)
  }

  public static func validate(_ reference: ReadStateReference, viewerDid: String) throws {
    let prefix = "at://\(viewerDid)/\(ReadStateChunk.collection)/"
    guard viewerDid.hasPrefix("did:"), reference.uri.hasPrefix(prefix),
          !reference.cid.isEmpty, reference.cid.utf8.count <= 256 else {
      throw ReadStateError.invalidReference
    }
    let key = String(reference.uri.dropFirst(prefix.count))
    guard !key.isEmpty, key != ".", key != "..", key.utf8.count <= 512,
          key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || [45, 46, 58, 95, 126].contains($0) }) else {
      throw ReadStateError.invalidReference
    }
  }

  public static func validate(_ manifest: ReadStateManifest, viewerDid: String) throws {
    guard manifest.type == ReadStateManifest.collection, manifest.version == 1,
          !manifest.generation.isEmpty, manifest.generation.utf8.count <= 128,
          (0...maximumSequence).contains(manifest.lastSequence),
          manifest.head != nil || manifest.lastSequence == 0 else { throw ReadStateError.invalidRecord }
    if let head = manifest.head { try validate(head, viewerDid: viewerDid) }
    try validateSize(manifest)
  }

  public static func validate(_ chunk: ReadStateChunk, viewerDid: String) throws {
    guard chunk.type == ReadStateChunk.collection, chunk.version == 1,
          !chunk.operations.isEmpty, chunk.operations.count <= 128 else { throw ReadStateError.invalidRecord }
    for operation in chunk.operations { try validate(operation) }
    if let previous = chunk.previous { try validate(previous, viewerDid: viewerDid) }
    try validateSize(chunk)
  }

  public static func validate(_ operation: ReadStateOperation) throws {
    guard !operation.actionId.isEmpty, operation.actionId.utf8.count <= 128,
          (1...maximumSequence).contains(operation.sequence) else { throw ReadStateError.invalidRecord }
    _ = try date(operation.actedAt)
    if let calendar = operation.calendar {
      guard operation.selection == .exact,
            calendar.timeZone == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(calendar.timeZone),
            calendar.referenceDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
        throw ReadStateError.invalidRecord
      }
      _ = try date(calendar.cutoff)
      _ = try date(calendar.referenceDate + "T00:00:00Z")
    }
    switch operation.selection {
    case .exact:
      guard operation.boundaries == nil, let subjects = operation.subjectUris,
            !subjects.isEmpty, subjects.count <= 256,
            subjects.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }),
            Set(subjects).count == subjects.count else { throw ReadStateError.invalidRecord }
    case .boundaries:
      guard operation.subjectUris == nil, let boundaries = operation.boundaries,
            !boundaries.isEmpty, boundaries.count <= 128 else { throw ReadStateError.invalidRecord }
      for boundary in boundaries {
        let scope = boundary.scope
        guard !scope.publicationId.isEmpty, scope.publicationId.utf8.count <= 2048,
              scope.authorDid.hasPrefix("did:"), scope.authorDid.utf8.count <= 2048,
              scope.publicationSiteKeys.count <= 128,
              scope.publicationSiteKeys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }),
              boundary.entryId.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true else {
          throw ReadStateError.invalidRecord
        }
        _ = try date(boundary.createdAt)
      }
    }
  }

  public static func encodedByteCount<T: Encodable>(_ record: T) throws -> Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return try encoder.encode(record).count
  }

  public static func validateSize<T: Encodable>(_ record: T) throws {
    guard try encodedByteCount(record) <= maximumRecordBytes else { throw ReadStateError.sizeLimit }
  }
}
