import Foundation
import Observation

@MainActor
@Observable
final class SocialComposerModel {
    private let client: SocialWireSocialClient
    var segments: [SocialThreadDraftSegment]
    let replyRoot: SocialPostReference?
    let replyParent: SocialPostReference?
    private(set) var isPublishing = false
    private(set) var error: String?
    private(set) var completed = 0
    var isLocked: Bool { segments.contains { $0.published != nil } }
    var isValid: Bool { !segments.isEmpty && segments.allSatisfy(\.isValid) }

    init(client: SocialWireSocialClient, replyRoot: SocialPostReference? = nil, replyParent: SocialPostReference? = nil, quote: SocialPostReference? = nil) {
        self.client = client
        self.replyRoot = replyRoot
        self.replyParent = replyParent
        segments = [SocialThreadDraftSegment(quote: quote)]
    }

    func addSegment() { guard !isLocked else { return }; segments.append(.init()) }
    func removeSegment(id: UUID) { guard !isLocked, segments.count > 1 else { return }; segments.removeAll { $0.id == id } }
    func move(from offsets: IndexSet, to destination: Int) { guard !isLocked else { return }; segments.move(fromOffsets: offsets, toOffset: destination) }

    func publish() async -> Bool {
        guard isValid, !isPublishing else { return false }
        isPublishing = true
        error = nil
        defer { isPublishing = false }
        do {
            try await client.publishThread(segments, root: replyRoot, parent: replyParent) { [weak self] index, reference in
                guard let self, self.segments.indices.contains(index) else { return }
                self.segments[index].published = reference
                self.completed = self.segments.filter { $0.published != nil }.count
            }
            return true
        } catch {
            self.error = "Your Thread Could Not Be Finished. Retry to Continue Without Reposting Published Posts."
            return false
        }
    }
}
