import Foundation
import Logging

struct RoleLeaseDiagnosticSnapshot: Sendable {
  struct Backend: Codable, Sendable {
    let pid: Int
    let waitEventType: String?
    let waitEvent: String?
    let blockingPIDs: [Int]
    let blockersTruncated: Bool
    var applicationName: String? = nil
    var queryID: String? = nil
    var transactionAgeMilliseconds: Double? = nil
    var queryAgeMilliseconds: Double? = nil
  }

  let databaseTime: Date
  let ownerID: String?
  let fencingToken: Int64?
  let expiresAt: Date?
  let totalConnections: Int64
  let activeConnections: Int64
  let idleConnections: Int64
  let waitingConnections: Int64
  let backends: [Backend]
  let sampledBackendCandidates: Int64

  var metadata: Logger.Metadata {
    var result: Logger.Metadata = [
      "database_time": .string(databaseTime.ISO8601Format()),
      "lease_present": .string(ownerID == nil ? "false" : "true"),
      "connections_total": .stringConvertible(totalConnections),
      "connections_active": .stringConvertible(activeConnections),
      "connections_idle": .stringConvertible(idleConnections),
      "connections_waiting": .stringConvertible(waitingConnections),
      "backend_samples_truncated": .string(sampledBackendCandidates > 16 ? "true" : "false"),
      "backends": .array(backends.prefix(16).map { backend in
        .dictionary([
          "pid": .stringConvertible(backend.pid),
          "application_name": .string(Self.applicationCategory(backend.applicationName)),
          "query_id": .string(backend.queryID.flatMap(Int64.init).map(String.init) ?? "unavailable"),
          "transaction_age_ms": Self.elapsedMetadata(backend.transactionAgeMilliseconds),
          "query_age_ms": Self.elapsedMetadata(backend.queryAgeMilliseconds),
          "wait_event_type": .string(backend.waitEventType.map { Self.safeLabel($0, limit: 64) } ?? "none"),
          "wait_event": .string(backend.waitEvent.map { Self.safeLabel($0, limit: 64) } ?? "none"),
          "blocking_pids": .array(backend.blockingPIDs.prefix(16).map { .stringConvertible($0) }),
          "blocking_pids_truncated": .string(backend.blockersTruncated || backend.blockingPIDs.count > 16 ? "true" : "false"),
        ])
      }),
    ]
    if let ownerID { result["owner_id"] = .string(Self.safeLabel(ownerID, limit: 255)) }
    if let fencingToken { result["fencing_token"] = .stringConvertible(fencingToken) }
    if let expiresAt { result["lease_expires_at"] = .string(expiresAt.ISO8601Format()) }
    return result
  }

  /// Service names are operator-controlled but may accidentally contain sensitive values.
  /// Only exact known labels enter diagnostics; unknown names never become log dimensions.
  static func applicationCategory(_ value: String?) -> String {
    guard let value else { return "unknown" }
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 2 {
      let component = String(parts[1])
      let knownComponents = [
        "authority", "lease-diagnostics", "coordinator-appview", "projection-pool-appview",
        "appview-worker", "wire-combined", "wire-rank", "wire-drain",
      ]
      guard knownComponents.contains(component),
        applicationCategory(String(parts[0])) != "unknown" else { return "unknown" }
      return value
    }
    switch value {
    case "Coordinator", "coordinator", "coordinator-appview", "coordinator-wire",
      "coordinator-lease-diagnostics", "Projection-Pool", "projection-pool",
      "App-View", "appview", "thin-appview", "Gateway", "gateway",
      "Operations", "operations", "Ops", "Charybdis", "charybdis", "Wire", "wire-worker",
      "Corpus-Edge", "Wire-Corpus-Edge", "wire-corpus-edge", "Jetstream-V2-Ingest",
      "jetstream-ingest", "Ingress-Controller", "ingress-controller", "Database-Migrator",
      "appview.Ingress-Controller", "wire.Ingress-Controller", "wire-live.Ingress-Controller",
      "appview.ingress-controller", "wire.ingress-controller", "wire-live.ingress-controller",
      "wire-external.Ingress-Controller", "wire-publication.Ingress-Controller",
      "wire-publicationwest.Ingress-Controller", "wire-external.ingress-controller",
      "wire-publication.ingress-controller", "wire-publicationwest.ingress-controller",
      "appview.Jetstream-V2-Ingest", "wire.The-Wire-Global-Ingest-Production",
      "wire.The-Wire-Live-Ingest-Production",
      "The-Wire-Worker-Production", "The-Wire-Global-Ingest-Production",
      "The-Wire-Live-Ingest-Production":
      return value
    default:
      return "unknown"
    }
  }

  private static func elapsedMetadata(_ value: Double?) -> Logger.Metadata.Value {
    guard let value, value.isFinite else { return .string("unavailable") }
    // Clock corrections must not produce negative ages. Preserve fractional milliseconds.
    return .stringConvertible(max(0, value))
  }

  static func safeLabel(_ value: String, limit: Int) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
    return String(value.prefix(limit).map { allowed.contains($0) ? $0 : "-" })
  }
}
