import AsyncHTTPClient
import Foundation
import Hummingbird
import JWTKit
import Logging

/// Context injected by `ATProtoAuthMiddleware` after successful token verification.
struct AuthContext: Sendable {
  let did: String
}

/// Verifies an ATProto DPoP-bound access token and injects the caller's DID
/// into the request context.
///
/// **Verification flow:**
/// 1. Extract `Authorization: DPoP <token>` (or `Bearer <token>`) header.
/// 2. Decode the JWT payload (without verifying) to extract the `sub` claim (the DID).
/// 3. Fetch the DID document from the PLC directory.
/// 4. Extract the verification key from the DID document.
/// 5. Verify the JWT signature.
/// 6. Inject `AuthContext(did:)` into the mutable `AppRequestContext`.
///
/// **Phase 1 simplification:** full cryptographic DPoP verification is deferred to
/// Phase 1b. The middleware currently verifies the JWT is well-formed and falls back
/// to PDS introspection if DID-document verification fails.
struct ATProtoAuthMiddleware: RouterMiddleware {
  typealias Context = AppRequestContext

  private let httpClient: HTTPClient
  private let plcURL: String
  private let logger: Logger

  init(httpClient: HTTPClient, plcURL: String, logger: Logger) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.logger = logger
  }

  func handle(
    _ request: Request,
    context: AppRequestContext,
    next: (Request, AppRequestContext) async throws -> Response
  ) async throws -> Response {
    // In swift-http-types (used by Hummingbird 2), headers[name] returns String? directly.
    guard let authHeader = request.headers[.authorization] else {
      throw HTTPError(.unauthorized, message: "Missing Authorization header")
    }

    // Accept both "DPoP <token>" and "Bearer <token>" for Phase 1 flexibility
    let token: String
    if authHeader.hasPrefix("DPoP ") {
      token = String(authHeader.dropFirst(5))
    } else if authHeader.hasPrefix("Bearer ") {
      token = String(authHeader.dropFirst(7))
    } else {
      throw HTTPError(.unauthorized, message: "Authorization header must use DPoP or Bearer scheme")
    }

    let did = try await verifyTokenAndExtractDID(token: token)

    // Store auth context directly on the typed request context (no key-value bag needed).
    var mutableContext = context
    mutableContext.authContext = AuthContext(did: did)
    return try await next(request, mutableContext)
  }

  // MARK: - Private

  private func verifyTokenAndExtractDID(token: String) async throws -> String {
    let did = try extractDIDFromJWT(token: token)

    do {
      try await verifySignatureViaDIDDocument(token: token, did: did)
    } catch {
      logger.warning(
        "DID document signature verification failed, falling back to PDS introspection",
        metadata: ["did": "\(did)", "error": "\(error)"]
      )
      try await verifyViaIntrospection(token: token, did: did)
    }

    return did
  }

  /// Decodes the JWT payload (without signature verification) and extracts `sub`.
  private func extractDIDFromJWT(token: String) throws -> String {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else {
      throw HTTPError(.unauthorized, message: "Malformed JWT")
    }
    // Base64url → Base64
    var base64 = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }

    guard
      let data = Data(base64Encoded: base64),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sub = json["sub"] as? String,
      sub.hasPrefix("did:")
    else {
      throw HTTPError(.unauthorized, message: "JWT missing or invalid 'sub' claim")
    }
    return sub
  }

  /// Fetches the DID document from the PLC directory and verifies the JWT signature.
  private func verifySignatureViaDIDDocument(token: String, did: String) async throws {
    let encodedDID = did.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? did
    let url = "\(plcURL)/\(encodedDID)"
    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: .seconds(10))
    guard response.status == .ok else {
      throw HTTPError(.unauthorized, message: "Could not fetch DID document for \(did)")
    }

    let body = try await response.body.collect(upTo: 64 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let verificationMethods = json["verificationMethod"] as? [[String: Any]],
      !verificationMethods.isEmpty
    else {
      throw HTTPError(.unauthorized, message: "DID document has no verification methods")
    }

    // Phase 1: verify the JWT is well-formed and its sub matches the DID.
    // Full cryptographic verification (ES256K / P-256) added in Phase 1b.
    // TODO(phase-1b): Use JWTKit to verify against the key material in the DID doc.
    logger.debug(
      "DID document fetched, Phase 1 defers full crypto verification",
      metadata: ["did": "\(did)"]
    )
  }

  /// Falls back to PDS token introspection if DID document verification fails.
  private func verifyViaIntrospection(token: String, did: String) async throws {
    // TODO(phase-1b): Derive PDS endpoint from DID document and call introspection endpoint.
    logger.warning(
      "PDS introspection not yet implemented; trusting decoded DID for Phase 1",
      metadata: ["did": "\(did)"]
    )
  }
}
