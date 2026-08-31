import Foundation
import SwiftData

@Model
final class PersistedCircleEditionPage {
    @Attribute(.unique) var cacheKey: String
    var viewerDID: String
    var language: String
    var pagePayload: Data
    var cachedAt: Date

    init(
        cacheKey: String,
        viewerDID: String,
        language: String,
        pagePayload: Data,
        cachedAt: Date = Date()
    ) {
        self.cacheKey = cacheKey
        self.viewerDID = viewerDID
        self.language = language
        self.pagePayload = pagePayload
        self.cachedAt = cachedAt
    }
}
