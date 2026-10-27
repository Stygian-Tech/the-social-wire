import Foundation

struct SocialThreadDraftSegment: Identifiable, Sendable {
    let id: UUID
    var text: String
    var quote: SocialPostReference?
    var attachments: [SocialComposerAttachment]
    var published: StrongRef?

    init(id: UUID = UUID(), text: String = "", quote: SocialPostReference? = nil, attachments: [SocialComposerAttachment] = [], published: StrongRef? = nil) {
        self.id = id
        self.text = text
        self.quote = quote
        self.attachments = attachments
        self.published = published
    }

    var graphemeCount: Int { text.count }
    var byteCount: Int { text.lengthOfBytes(using: .utf8) }
    var isValid: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && graphemeCount <= 300 && byteCount <= 3_000 && attachments.count <= 4
    }
}
