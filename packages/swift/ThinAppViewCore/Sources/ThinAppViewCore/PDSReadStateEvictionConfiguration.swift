import Foundation

public struct PDSReadStateEvictionConfiguration: Sendable {
  public let enabled: Bool
  public let idleSeconds: TimeInterval
  public static let disabled = Self(enabled: false, idleSeconds: 7 * 86_400)

  public init(enabled: Bool, idleSeconds: TimeInterval = 7 * 86_400) {
    self.enabled = enabled
    self.idleSeconds = max(7 * 86_400, idleSeconds.isFinite ? idleSeconds : 7 * 86_400)
  }

  public static func fromEnvironment(_ values: [String: String]) -> Self {
    Self(enabled: values["THIN_APPVIEW_PDS_READ_STATE_EVICTION_ENABLED"] == "true",
      idleSeconds: (Double(values["THIN_APPVIEW_PDS_READ_STATE_IDLE_DAYS"] ?? "") ?? 7) * 86_400)
  }
}
