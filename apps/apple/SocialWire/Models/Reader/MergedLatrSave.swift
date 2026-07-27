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

    var rowSubtitle: String {
        switch self {
        case .external(let save):
            save.rowSubtitle ?? Self.fallbackRowSubtitle(from: save)
        case .native(let save):
            save.rowSubtitle ?? Self.fallbackRowSubtitle(from: save)
        }
    }

    private static func fallbackRowSubtitle(from save: MergedLatrExternalSave) -> String {
        EntryDisplayDate.savedLinkRowSubtitle(
            site: save.site,
            previewHost: URL(string: save.url)?.host,
            author: save.author,
            publishedAt: save.publishedAt,
            savedAt: save.savedAt
        )
    }

    private static func fallbackRowSubtitle(from save: MergedLatrNativeSave) -> String {
        EntryDisplayDate.savedLinkRowSubtitle(
            site: save.site,
            previewHost: save.url.flatMap(URL.init(string:))?.host
                ?? save.linkedWebUrl.flatMap(URL.init(string:))?.host,
            author: save.author,
            publishedAt: save.publishedAt,
            savedAt: save.savedAt
        )
    }

    var state: String? {
        switch self {
        case .external(let save): save.state
        case .native(let save): save.state
        }
    }

    var lastOpenedAt: String? {
        switch self {
        case .external(let save): save.lastOpenedAt
        case .native(let save): save.lastOpenedAt
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
