import Foundation
import SwiftData

@Model
final class PersistedWireItemDetail {
    @Attribute(.unique) var cacheKey: String
    var viewerDID: String
    var itemId: String
    var detailPayload: Data
    var cachedAt: Date

    init(
        cacheKey: String,
        viewerDID: String,
        itemId: String,
        detailPayload: Data,
        cachedAt: Date = Date()
    ) {
        self.cacheKey = cacheKey
        self.viewerDID = viewerDID
        self.itemId = itemId
        self.detailPayload = detailPayload
        self.cachedAt = cachedAt
    }
}
