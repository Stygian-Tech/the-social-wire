import Foundation
import OperationsCore

struct WorkerReadinessDiagnostics: Sendable, Equatable {
  let logMetadata: [String: String]

  static func v2(
    from state: OperationsServiceState,
    at now: Date
  ) -> WorkerReadinessDiagnostics? {
    guard
      state.dependencyState["ingestion_source"]
        == OperationsEvidenceResolver.durableJetstreamV2AuthoritySource
    else { return nil }

    let observationAge = max(0, now.timeIntervalSince(state.heartbeatAt))
    let dependency = state.dependencyState
    return WorkerReadinessDiagnostics(
      logMetadata: [
        "v2_source_generation": boundedIdentifier(
          dependency["jetstream_v2_source_generation"]
        ),
        "v2_replay_state": boundedReplayState(
          dependency["jetstream_v2_replay_state"]
        ),
        "v2_lease_heartbeat_age_seconds": boundedAge(
          dependency["jetstream_v2_intake_heartbeat_age_seconds"],
          observationAge: observationAge
        ),
        "v2_inbox_pending": boundedCount(
          dependency["jetstream_v2_inbox_pending"]
        ),
        "v2_inbox_leased": boundedCount(
          dependency["jetstream_v2_inbox_leased"]
        ),
        "v2_inbox_retrying": boundedCount(
          dependency["jetstream_v2_inbox_retrying"]
        ),
        "v2_inbox_dead_letters": boundedCount(
          dependency["jetstream_v2_dead_letters"]
        ),
        "v2_oldest_actionable_age_seconds": boundedAge(
          dependency["jetstream_v2_inbox_oldest_actionable_age_seconds"],
          observationAge: observationAge
        ),
        "v2_checkpoint_age_seconds": boundedAge(
          dependency["jetstream_v2_checkpoint_age_seconds"],
          observationAge: observationAge
        ),
      ]
    )
  }

  private static func boundedIdentifier(_ raw: String?) -> String {
    guard let raw else { return "unknown" }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 96 else { return "invalid" }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
    guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return "invalid" }
    return trimmed
  }

  private static func boundedReplayState(_ raw: String?) -> String {
    guard let raw, JetstreamReplayState(rawValue: raw) != nil else { return "unknown" }
    return raw
  }

  private static func boundedCount(_ raw: String?) -> String {
    guard let raw, let value = UInt64(raw) else { return "unknown" }
    let maximum: UInt64 = 1_000_000_000
    return value <= maximum ? String(value) : "1000000000+"
  }

  private static func boundedAge(
    _ raw: String?,
    observationAge: TimeInterval
  ) -> String {
    if raw == "31536000+" { return "31536000+" }
    guard let raw, let value = TimeInterval(raw), value.isFinite, value >= 0 else {
      return "unknown"
    }
    let currentAge = value + max(0, observationAge)
    let maximum: TimeInterval = 31_536_000
    guard currentAge.isFinite, currentAge <= maximum else { return "31536000+" }
    return String(Int(currentAge.rounded(.down)))
  }
}
