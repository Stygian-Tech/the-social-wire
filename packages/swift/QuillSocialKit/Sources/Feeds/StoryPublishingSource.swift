import Foundation

public protocol StoryPublishingSource: Sendable {
    func publishPhoto(data: Data, mimeType: String) async throws -> String
}
