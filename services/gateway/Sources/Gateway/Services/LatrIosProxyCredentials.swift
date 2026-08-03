import Foundation
import GatewayCore

/// Server-side L@tr credentials for the Social Wire Gateway **iOS proxy** (`/v1/latr/*`).
///
/// These are distinct from the web frontend's `/api/latr-gateway` variables
/// (`LATR_GATEWAY_*`). Both paths talk to the external L@tr Gateway, but the
/// Social Wire Gateway uses `LATR_IOS_PROXY_*`.
enum LatrIosProxyCredentials {
  static let urlEnvKey = "LATR_IOS_PROXY_URL"
  static let clientIdEnvKey = "LATR_IOS_PROXY_CLIENT_ID"
  static let apiKeyEnvKey = "LATR_IOS_PROXY_API_KEY"
  static let clientCredentialEnvKey = "LATR_IOS_PROXY_CLIENT_CREDENTIAL"

  static let clientIdHeaderName = "X-Latr-Client-Id"
  static let apiKeyHeaderName = "X-Latr-API-Key"
  static let officialClientHeaderName = "X-Latr-Official-Client"

  struct Config: Sendable {
    let baseURL: String
    let clientId: String?
    let apiKey: String?
    let officialClientCredential: String?

    var hasServerCredentials: Bool {
      if let clientId, let apiKey, !clientId.isEmpty, !apiKey.isEmpty {
        return true
      }
      if let officialClientCredential, !officialClientCredential.isEmpty {
        return true
      }
      return false
    }

    func authHeaders() -> [String: String] {
      if let officialClientCredential, !officialClientCredential.isEmpty {
        return [officialClientHeaderName: officialClientCredential]
      }
      if let clientId, let apiKey, !clientId.isEmpty, !apiKey.isEmpty {
        return [
          clientIdHeaderName: clientId,
          apiKeyHeaderName: apiKey,
        ]
      }
      return [:]
    }

    static func fromEnvironment(
      _ env: [String: String] = AppEnvironmentLoader.mergeProcessWithDotenv()
    ) -> Config? {
      let baseRaw = trimmedEnv(env, urlEnvKey)
      guard let baseRaw, !baseRaw.isEmpty else { return nil }
      let baseURL = baseRaw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let clientId = trimmedEnv(env, clientIdEnvKey)
      let apiKey = trimmedEnv(env, apiKeyEnvKey)
      let official = trimmedEnv(env, clientCredentialEnvKey)
      return Config(
        baseURL: baseURL,
        clientId: clientId,
        apiKey: apiKey,
        officialClientCredential: official
      )
    }

    static func credentialsHelpText() -> String {
      """
      Set \(urlEnvKey) plus \(clientIdEnvKey) and \(apiKeyEnvKey), \
      or \(clientCredentialEnvKey) for the official first-party credential.
      """
    }

    private static func trimmedEnv(_ env: [String: String], _ key: String) -> String? {
      let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let raw, !raw.isEmpty else { return nil }
      return raw
    }
  }
}
