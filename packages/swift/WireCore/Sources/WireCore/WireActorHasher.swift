import Crypto
import Foundation

public struct WireActorHasher: Sendable {
  private let secret: Data

  public init(secret: Data) throws {
    guard secret.count >= 32 else { throw WireActorHasherError.invalidSecret }
    self.secret = secret
  }

  public func hash(_ actorID: String) throws -> String {
    let normalized = actorID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { throw WireActorHasherError.invalidActorID }
    let digest = HMAC<SHA256>.authenticationCode(
      for: Data(normalized.utf8),
      using: SymmetricKey(data: secret)
    )
    return "h1:" + digest.map { String(format: "%02x", $0) }.joined()
  }
}
