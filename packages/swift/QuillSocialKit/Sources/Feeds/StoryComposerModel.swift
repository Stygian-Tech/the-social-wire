import Foundation
import Observation

@MainActor
@Observable
public final class StoryComposerModel {
    public private(set) var imageData: Data?
    public private(set) var mimeType = "image/jpeg"
    public private(set) var isPublishing = false
    public private(set) var didFail = false

    public init() {}

    public func selectPhoto(data: Data, mimeType: String) {
        guard !isPublishing else { return }
        imageData = data
        self.mimeType = mimeType
        didFail = false
    }

    public func publish(using source: any StoryPublishingSource) async -> Bool {
        guard !isPublishing, let imageData else { return false }
        isPublishing = true
        defer { isPublishing = false }
        do {
            _ = try await source.publishPhoto(data: imageData, mimeType: mimeType)
            didFail = false
            return true
        } catch {
            didFail = true
            return false
        }
    }
}
