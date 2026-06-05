import Foundation
import HTTPTypes
import Hummingbird

/// Client-supplied DPoP proof bound to the external L@tr Gateway URL for Social Wire proxy forwarding.
public enum LatrGatewayUpstreamDPoP {
  public static let headerName = "X-Latr-Gateway-DPoP"

  public static func extract(from request: Request) -> String? {
    guard let fieldName = HTTPField.Name(headerName) else { return nil }
    let proof = request.headers[fieldName]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let proof, !proof.isEmpty else { return nil }
    return proof
  }
}
