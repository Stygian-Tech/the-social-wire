import Foundation

struct SocialComposerAttachment: Identifiable, Sendable {
    let id: UUID
    let data: Data
    let mimeType: String
    var altText: String

    init(id: UUID = UUID(), data: Data, mimeType: String, altText: String = "") {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.altText = altText
    }
}
