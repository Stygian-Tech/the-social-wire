import Foundation

enum ArticleOpenMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case original
    case reader

    var id: Self { self }

    var title: String {
        switch self {
        case .original:
            "Original Website"
        case .reader:
            "Native Reader"
        }
    }
}
