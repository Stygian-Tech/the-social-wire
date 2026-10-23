import Foundation
import Synchronization

struct SocialThreadDraftSegment: Identifiable, Sendable {
    let recordKey: String
    let createdAt: String
    let id: UUID
    var text: String
    var quote: SocialPostReference?
    var attachments: [SocialComposerAttachment]
    var published: StrongRef?

    init(id: UUID = UUID(), text: String = "", quote: SocialPostReference? = nil, attachments: [SocialComposerAttachment] = [], published: StrongRef? = nil) {
        self.recordKey = Self.nextRecordKey()
        self.createdAt = DateFormatters.string()
        self.id = id
        self.text = text
        self.quote = quote
        self.attachments = attachments
        self.published = published
    }

    private static let lastRecordValue = Mutex<UInt64>(0)

    private static func nextRecordKey() -> String {
        // ATProto TIDs use microseconds and a 10-bit clock ID with sortable base32.
        // Monotonic allocation keeps segments created in one clock tick distinct.
        var value = lastRecordValue.withLock { previous in
            let clock = UInt64.random(in: 0..<1024)
            let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            previous = max(previous + 1, (timestamp << 10) | clock)
            return previous
        }
        let alphabet = Array("234567abcdefghijklmnopqrstuvwxyz")
        var encoded = Array(repeating: Character("2"), count: 13)
        for index in stride(from: 12, through: 0, by: -1) {
            encoded[index] = alphabet[Int(value & 31)]
            value >>= 5
        }
        return String(encoded)
    }

    var graphemeCount: Int { text.count }
    var byteCount: Int { text.lengthOfBytes(using: .utf8) }
    var isValid: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && graphemeCount <= 300 && byteCount <= 3_000 && attachments.count <= 4
    }
}
