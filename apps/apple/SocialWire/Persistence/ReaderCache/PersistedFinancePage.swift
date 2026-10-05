import Foundation
import SwiftData

@Model
final class PersistedFinancePage {
    @Attribute(.unique) var contextKey: String
    var viewerDID: String
    var generationID: String
    var pagePayload: Data
    var cachedAt: Date

    init(contextKey: String, viewerDID: String, generationID: String, pagePayload: Data) {
        self.contextKey = contextKey
        self.viewerDID = viewerDID
        self.generationID = generationID
        self.pagePayload = pagePayload
        self.cachedAt = Date()
    }
}
