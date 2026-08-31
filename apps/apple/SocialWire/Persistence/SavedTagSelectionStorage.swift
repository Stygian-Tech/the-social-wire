import Foundation

enum SavedTagSelectionStorage {
    private static let prefix = "the-social-wire.saved-tag-selection.v1"

    static func load(
        viewerDid: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        defaults.string(forKey: key(viewerDid: viewerDid))
    }

    static func save(
        _ tag: String?,
        viewerDid: String,
        defaults: UserDefaults = .standard
    ) {
        let storageKey = key(viewerDid: viewerDid)
        if let tag {
            defaults.set(tag, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private static func key(viewerDid: String) -> String {
        "\(prefix):\(viewerDid)"
    }
}
