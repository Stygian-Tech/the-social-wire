import Foundation
import HTTPTypes
import Hummingbird

/// A single client proof bound to the viewer PDS `com.atproto.server.getSession` endpoint.
/// This is intentionally separate from route-specific `X-ATProto-Upstream-DPoP` proof pools.
public enum ATProtoSessionDPoP {
  public static let headerName = "X-ATProto-Session-DPoP"
  public static let nonceHeaderName = "X-ATProto-Session-DPoP-Nonce"
  static let maximumProofBytes = 8 * 1024

  static func extract(from request: Request) -> String? {
    guard let fieldName = HTTPField.Name(headerName) else { return nil }
    return validatedProof(request.headers[fieldName])
  }

  static func validatedProof(_ raw: String?) -> String? {
    guard let proof = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
      !proof.isEmpty,
      proof.utf8.count <= maximumProofBytes,
      !proof.contains(",")
    else { return nil }
    return proof
  }
}
