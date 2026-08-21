import HTTPTypes
import Hummingbird

public enum WireModerationDPoP {
  public static let headerName = "X-Wire-Moderation-DPoP"
  public static let appViewColdPathTimeoutSeconds: Int64 = 25
  public static let gatewayProxyTimeoutSeconds: Int64 = 30

  public static let methods = [
    "app.bsky.actor.getPreferences",
    "app.bsky.graph.getBlocks",
    "app.bsky.graph.getMutes",
    "app.bsky.graph.getListMutes",
    "app.bsky.graph.getListBlocks",
  ]

  public static func extract(from request: Request) -> [String]? {
    guard let name = HTTPField.Name(headerName), let raw = request.headers[name] else { return nil }
    let proofs = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard proofs.count == methods.count, proofs.allSatisfy({ !$0.isEmpty }) else { return nil }
    return proofs
  }
}
