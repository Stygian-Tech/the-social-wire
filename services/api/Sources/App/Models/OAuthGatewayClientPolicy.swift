import Foundation
import Hummingbird

/// First-party OAuth client binding for the hosted Swift API (**not** spoofable UA headers).
///
/// When `requireKnownClient` is `true`, a request must satisfy at least one allowlist slice that is configured
/// nonempty: **`client_id` / `azp`** ⊆ `allowedClientIds`, **or** **JWT `aud`** ∩ `allowedAudiences`.
struct OAuthGatewayClientPolicy: Sendable {
  let allowedClientIds: Set<String>
  let allowedAudiences: Set<String>
  let requireKnownClient: Bool

  static let permissive = OAuthGatewayClientPolicy(
    allowedClientIds: [],
    allowedAudiences: [],
    requireKnownClient: false
  )

  func assertAllowedJWTClient(
    clientIdClaim: String?,
    azpClaim: String?,
    audiences: [String]
  ) throws {
    guard requireKnownClient else { return }

    if allowedClientIds.isEmpty, allowedAudiences.isEmpty {
      throw HTTPError(
        .forbidden,
        message: "Gateway client policy is enabled but no allowlists are configured"
      )
    }

    var allowed = false

    if !allowedClientIds.isEmpty {
      if let clientIdClaim, allowedClientIds.contains(clientIdClaim) {
        allowed = true
      }
      if !allowed, let azpClaim, allowedClientIds.contains(azpClaim) {
        allowed = true
      }
    }

    if !allowed, !allowedAudiences.isEmpty {
      for value in audiences where allowedAudiences.contains(value) {
        allowed = true
        break
      }
    }

    if !allowed {
      throw HTTPError(.forbidden, message: "OAuth client is not authorized for this gateway")
    }
  }
}

enum OAuthGatewayPolicyParser {
  static func delimiterTokenSet(_ raw: String?) -> Set<String> {
    guard let raw else { return [] }
    let tokens = raw
      .split { $0.isWhitespace || $0 == "," }
      .map(String.init)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return Set(tokens)
  }

  static func truthy(_ value: String?) -> Bool {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !trimmed.isEmpty
    else {
      return false
    }
    return ["1", "true", "yes", "on"].contains(trimmed)
  }
}
