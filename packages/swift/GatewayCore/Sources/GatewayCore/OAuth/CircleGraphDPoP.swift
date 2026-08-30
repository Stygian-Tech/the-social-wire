import HTTPTypes
import Hummingbird

public enum CircleGraphDPoP {
  public static let headerName = "X-Circle-Graph-DPoP"

  public static let methods = WireModerationDPoP.methods + [
    "com.atproto.repo.listRecords"
  ]

  public static func extract(from request: Request) -> [String]? {
    guard let name = HTTPField.Name(headerName), let raw = request.headers[name] else { return nil }
    let proofs = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard proofs.count == methods.count, proofs.allSatisfy({ !$0.isEmpty }) else { return nil }
    return proofs
  }
}
