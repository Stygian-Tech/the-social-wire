import Foundation

struct SembleProjectionConfig: Equatable, Sendable {
  static let defaultBaseURL = "https://api.semble.so/api"

  let baseURL: String

  static func fromEnvironment(_ env: [String: String]) -> SembleProjectionConfig {
    let configured = env["SEMBLE_PUBLIC_API_BASE_URL"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = configured?.isEmpty == false ? configured! : defaultBaseURL
    return SembleProjectionConfig(baseURL: selected.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
  }
}
