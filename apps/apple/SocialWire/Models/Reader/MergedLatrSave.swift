import Foundation

enum MergedLatrSave: Identifiable, Codable, Equatable, Hashable, Sendable {
    case external(MergedLatrExternalSave)
    case native(MergedLatrNativeSave)

    var id: String {
        switch self {
        case .external(let save): "external:\(save.normalizedUrl)"
        case .native(let save): "native:\(save.itemUri)"
        }
    }

    var title: String {
        switch self {
        case .external(let save): save.title ?? URL(string: save.url)?.host ?? save.url
        case .native(let save): save.title ?? save.subjectUri
        }
    }

    var url: URL? {
        switch self {
        case .external(let save): URL(string: save.url)
        case .native(let save): save.url.flatMap(URL.init(string:)) ?? save.linkedWebUrl.flatMap(URL.init(string:))
        }
    }

    var itemRkey: String {
        switch self {
        case .external(let save): save.itemRkey
        case .native(let save): save.itemRkey
        }
    }

    var excerpt: String? {
        switch self {
        case .external(let save): save.excerpt
        case .native(let save): save.excerpt
        }
    }

    var image: String? {
        switch self {
        case .external(let save): save.image
        case .native(let save): save.image
        }
    }

    var site: String? {
        switch self {
        case .external(let save): save.site
        case .native(let save): save.site
        }
    }

    var author: String? {
        switch self {
        case .external(let save): save.author
        case .native(let save): save.author
        }
    }

    var publishedAt: String? {
        switch self {
        case .external(let save): save.publishedAt
        case .native(let save): save.publishedAt
        }
    }

    var savedAt: String {
        switch self {
        case .external(let save): save.savedAt
        case .native(let save): save.savedAt
        }
    }

    var state: String? {
        switch self {
        case .external(let save): save.state
        case .native(let save): save.state
        }
    }

    var linkedWebUrl: String? {
        switch self {
        case .external(let save): save.linkedWebUrl
        case .native(let save): save.linkedWebUrl
        }
    }

    var subjectUri: String? {
        switch self {
        case .external(let save): save.subjectUri
        case .native(let save): save.subjectUri
        }
    }

    func withState(_ state: String) -> MergedLatrSave {
        switch self {
        case .external(var save):
            save.state = state
            return .external(save)
        case .native(var save):
            save.state = state
            return .native(save)
        }
    }
}
