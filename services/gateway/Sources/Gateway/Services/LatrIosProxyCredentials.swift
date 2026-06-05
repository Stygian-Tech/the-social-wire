import Foundation
import GatewayCore

/// Server-side L@tr credentials for the Social Wire Gateway **iOS proxy** (`/v1/latr/*`).
///
/// These are distinct from the web client's Vercel `/api/latr-gateway` secrets
/// (`LATR_GATEWAY_*` on the Next.js host). Both paths talk to the external L@tr Gateway,
/// but Fly/runtime secrets for this proxy should use `LATR_IOS_PROXY_*`.
enum LatrIosProxyCredentials {
  static let urlEnvKey = "LATR_IOS_PROXY_URL"
  static let clientIdEnvKey = "LATR_IOS_PROXY_CLIENT_ID"
  static let apiKeyEnvKey = "LATR_IOS_PROXY_API_KEY"
  static let clientCredentialEnvKey = "LATR_IOS_PROXY_CLIENT_CREDENTIAL"

  /// Deprecated aliases kept for early parity deploys; prefer `LATR_IOS_PROXY_*`.
  static let legacyUrlEnvKey = "LATR_GATEWAY_URL"
  static let legacyClientIdEnvKey = "LATR_GATEWAY_CLIENT_ID"
  static let legacyApiKeyEnvKey = "LATR_GATEWAY_API_KEY"
  static let legacyClientCredentialEnvKey = "LATR_GATEWAY_CLIENT_CREDENTIAL"
  static let legacyOfficialClientCredentialsEnvKey = "LATR_GATEWAY_OFFICIAL_CLIENT_CREDENTIALS"

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
      let baseRaw = envValue(env, primary: urlEnvKey, legacy: legacyUrlEnvKey)
      guard let baseRaw, !baseRaw.isEmpty else { return nil }
      let baseURL = baseRaw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let clientId = envValue(env, primary: clientIdEnvKey, legacy: legacyClientIdEnvKey)
      let apiKey = envValue(env, primary: apiKeyEnvKey, legacy: legacyApiKeyEnvKey)
      let official =
        envValue(env, primary: clientCredentialEnvKey, legacy: legacyClientCredentialEnvKey)
        ?? trimmedEnv(env, legacyOfficialClientCredentialsEnvKey)
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
      or \(clientCredentialEnvKey) for the official first-party credential. \
      (\(legacyUrlEnvKey) and related LATR_GATEWAY_* names are deprecated aliases for this iOS proxy.)
      """
    }

    private static func envValue(
      _ env: [String: String],
      primary: String,
      legacy: String?
    ) -> String? {
      if let value = trimmedEnv(env, primary) { return value }
      guard let legacy else { return nil }
      return trimmedEnv(env, legacy)
    }

    private static func trimmedEnv(_ env: [String: String], _ key: String) -> String? {
      let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let raw, !raw.isEmpty else { return nil }
      return raw
    }
  }
}
