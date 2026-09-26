import Foundation

enum ReaderFilter: String, CaseIterable, Identifiable {
    private static let userDefaultsKey = "the-social-wire.reader-filter.v1"

    case all = "All"
    case unread = "Unread"

    var id: String { rawValue }

    static func loadSaved() -> ReaderFilter {
        guard let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey),
              let filter = ReaderFilter(rawValue: rawValue) else {
            return .all
        }
        return filter
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
    }
}
