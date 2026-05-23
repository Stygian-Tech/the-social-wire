import Foundation
import HTTPTypes
import Hummingbird

/// Optional client-supplied DPoP proof bound to the viewer PDS XRPC URL for gateway write-through.
public enum ATProtoUpstreamDPoP {
  public static let headerName = "X-ATProto-Upstream-DPoP"

  public static func extract(from request: Request) -> String? {
    guard let fieldName = HTTPField.Name(headerName) else { return nil }
    let proof = request.headers[fieldName]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let proof, !proof.isEmpty else { return nil }
    return proof
  }
}
