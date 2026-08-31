import Foundation
import SwiftData

@Model
final class PersistedCircleItemDetail {
    @Attribute(.unique) var cacheKey: String
    var viewerDID: String
    var storyId: String
    var detailPayload: Data
    var cachedAt: Date

    init(
        cacheKey: String,
        viewerDID: String,
        storyId: String,
        detailPayload: Data,
        cachedAt: Date = Date()
    ) {
        self.cacheKey = cacheKey
        self.viewerDID = viewerDID
        self.storyId = storyId
        self.detailPayload = detailPayload
        self.cachedAt = cachedAt
    }
}
