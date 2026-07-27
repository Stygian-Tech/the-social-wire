import Foundation

enum FeedSelection: Codable, Hashable {
    case topLevel(ReaderListSource)
    case folder(String)
    case publication(String)
    case savedSource(ReaderListSource, String)

    var topLevelSource: ReaderListSource? {
        if case let .topLevel(source) = self { return source }
        return nil
    }
}

enum FeedSelectionStorage {
    private static let prefix = "the-social-wire.feed-selection.v1"

    static func load(viewerDid: String) -> FeedSelection? {
        guard let data = UserDefaults.standard.data(forKey: "\(prefix):\(viewerDid)") else {
            return nil
        }
        return try? JSONDecoder().decode(FeedSelection.self, from: data)
    }

    static func save(_ selection: FeedSelection, viewerDid: String) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        UserDefaults.standard.set(data, forKey: "\(prefix):\(viewerDid)")
    }
}
