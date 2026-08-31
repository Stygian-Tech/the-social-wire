import Foundation

struct SavedTagCount: Identifiable, Equatable, Sendable {
    let tag: String
    let count: Int

    var id: String { tag }
}

enum SavedTagCatalog {
    static func counts(in saves: [MergedLatrSave]) -> [SavedTagCount] {
        var counts: [String: Int] = [:]
        for save in saves {
            for tag in Set(save.tags) {
                counts[tag, default: 0] += 1
            }
        }
        return counts.map { SavedTagCount(tag: $0.key, count: $0.value) }
            .sorted {
                let order = $0.tag.localizedCaseInsensitiveCompare($1.tag)
                return order == .orderedSame ? $0.tag < $1.tag : order == .orderedAscending
            }
    }
}
