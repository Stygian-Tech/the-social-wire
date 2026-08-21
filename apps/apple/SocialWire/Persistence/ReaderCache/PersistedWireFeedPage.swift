import Foundation
import SwiftData

@Model
final class PersistedWireFeedPage {
    @Attribute(.unique) var language: String
    var viewerDID: String = ""
    var pagePayload: Data
    var cachedAt: Date

    init(
        language: String,
        viewerDID: String,
        pagePayload: Data,
        cachedAt: Date = Date()
    ) {
        self.language = language
        self.viewerDID = viewerDID
        self.pagePayload = pagePayload
        self.cachedAt = cachedAt
    }
}
