import Foundation

public enum OperationsEvidenceResolver {
  public static let requiredServiceNames = ["gateway", "appview", "appview-worker", "operations"]

  public static func services(
    _ states: [OperationsServiceState],
    requiredServices: [String] = requiredServiceNames,
    source: String = "operations_service_state",
    at: Date = Date(),
    validitySeconds: TimeInterval = 45
  ) -> OperationsEvidenceMetadata {
    let selected = requiredServices.compactMap { requiredService in
      states.filter { $0.service == requiredService }
        .max(by: { $0.heartbeatAt < $1.heartbeatAt })
    }
    let freshNames = Set(selected.filter {
      at.timeIntervalSince($0.heartbeatAt) <= validitySeconds
    }.map(\.service))
    let missingOrExpired = requiredServices.filter { !freshNames.contains($0) }
    let watermark = selected.map(\.heartbeatAt).min()
    let unavailable = freshNames.isEmpty
    let complete = missingOrExpired.isEmpty
    return OperationsEvidenceMetadata(
      source: source,
      accuracy: unavailable ? .unavailable : (complete ? .exact : .sampled),
      generatedAt: at,
      indexedThrough: watermark,
      ageSeconds: watermark.map { max(0, at.timeIntervalSince($0)) } ?? 0,
      validUntil: watermark?.addingTimeInterval(validitySeconds) ?? at,
      coverage: requiredServices.isEmpty
        ? 0 : Double(freshNames.count) / Double(requiredServices.count),
      lastSuccessfulAt: watermark,
      degradedReason: complete ? nil
        : "Missing or expired required service evidence: \(missingOrExpired.joined(separator: ", ")).")
  }

  public static func ingestionAuthority(
    services: [OperationsServiceState],
    streams: [IngestionStreamState],
    at: Date = Date()
  ) -> (state: IngestionStreamState?, evidence: OperationsEvidenceMetadata) {
    let worker = services.filter {
      $0.service == "appview-worker" && at.timeIntervalSince($0.heartbeatAt) <= 15
    }.max(by: { $0.heartbeatAt < $1.heartbeatAt })
    let advertised = worker?.dependencyState["ingestion_authority"]
    let authoritySource = advertised.flatMap {
      ["jetstream", "tap"].contains($0) ? $0 : nil
    }
    let authorityState = authoritySource.flatMap { source in
      streams.first(where: { $0.source == source })
    }
    let heartbeat = authorityState?.transportHeartbeatAt
    let heartbeatIsFresh = heartbeat.map { at.timeIntervalSince($0) <= 45 } ?? false
    let degradedReason: String?
    if authoritySource == nil {
      degradedReason = "No fresh ingestion-authority capability evidence is available."
    } else if heartbeat == nil {
      degradedReason = "No transport heartbeat exists for the authoritative ingestion source."
    } else if !heartbeatIsFresh {
      degradedReason = "The authoritative ingestion transport heartbeat has expired."
    } else {
      degradedReason = nil
    }
    return (
      authorityState,
      OperationsEvidenceMetadata(
        source: "appview_ingestion_stream_state",
        accuracy: heartbeatIsFresh ? .exact : .unavailable,
        generatedAt: at,
        indexedThrough: heartbeat,
        ageSeconds: heartbeat.map { max(0, at.timeIntervalSince($0)) } ?? 0,
        validUntil: heartbeat?.addingTimeInterval(45) ?? at,
        coverage: heartbeatIsFresh ? 1 : 0,
        lastSuccessfulAt: heartbeat,
        degradedReason: degradedReason)
    )
  }
}
