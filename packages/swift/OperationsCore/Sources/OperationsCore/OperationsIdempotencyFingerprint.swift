import Crypto
import Foundation

/// Binds an idempotency key to the complete semantic request that first used it.
/// Length-prefixed components avoid delimiter ambiguity while sorted field names keep the
/// representation stable across processes and database backends.
enum OperationsIdempotencyFingerprint {
  static func make(
    action: String,
    targetType: String,
    targetId: String?,
    expectedVersion: Int?,
    fields: [String: String?]
  ) -> String {
    var components = [
      component("action", action),
      component("targetType", targetType),
      component("targetId", targetId ?? "<nil>"),
      component("expectedVersion", expectedVersion.map(String.init) ?? "<nil>"),
    ]
    for key in fields.keys.sorted() {
      let value = (fields[key] ?? nil) ?? "<nil>"
      components.append(component(key, value))
    }
    let digest = SHA256.hash(data: Data(components.joined().utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func component(_ name: String, _ value: String) -> String {
    "\(name.utf8.count):\(name)\(value.utf8.count):\(value)"
  }
}
