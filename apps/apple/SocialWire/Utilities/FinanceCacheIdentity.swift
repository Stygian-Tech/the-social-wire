import CryptoKit
import Foundation

enum FinanceCacheIdentity {
    static func key(viewer: String, language: String, region: String, moderation: String, preferences: String, generation: String, feed: String = "finance") -> String {
        let components = [viewer, language, region, moderation, preferences, generation, feed]
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
