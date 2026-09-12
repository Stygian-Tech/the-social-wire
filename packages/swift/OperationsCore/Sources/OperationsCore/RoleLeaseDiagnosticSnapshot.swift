import Foundation
import Logging

struct RoleLeaseDiagnosticSnapshot: Sendable {
  struct Backend: Codable, Sendable {
    let pid: Int
    let waitEventType: String?
    let waitEvent: String?
    let blockingPIDs: [Int]
    let blockersTruncated: Bool
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

  static func safeLabel(_ value: String, limit: Int) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
    return String(value.prefix(limit).map { allowed.contains($0) ? $0 : "-" })
  }
}
