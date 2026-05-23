import Foundation
import GatewayCore
import Logging

/// Persisted bootstrap sidebar snapshot for stale-first AppView loads.
struct BootstrapSidebarCacheSnapshot: Codable, Sendable {
  let priority: PublicationSidebarResponse
  let folderPayload: AppViewBootstrapSidebarFoldersPayload?
}

enum BootstrapStreamTimings {
  static func logPhase(
    _ logger: Logger,
    phase: String,
    startedAt: Date,
    viewerDid: String,
    extra: [String: String] = [:]
  ) {
    let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
    var metadata: Logger.Metadata = [
      "phase": .string(phase),
      "durationMs": .stringConvertible(ms),
      "viewerDid": .string(viewerDid),
    ]
    for (key, value) in extra {
      metadata[key] = .string(value)
    }
    logger.info("Bootstrap stream phase", metadata: metadata)
  }
}
