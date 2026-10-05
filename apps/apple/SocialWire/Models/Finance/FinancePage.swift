import Foundation

struct FinancePage: Codable, Equatable, Sendable {
    var feedId: String = "finance"
    var widgetsEnabled: Bool? = nil
    let items: [FinanceFeedItem]
    let generationId: String
    let generatedAt: String
    let expiresAt: String
    let language: String
    let preferenceRevision: String
    let cursor: String?
    let source: String
    let degraded: Bool
}
