import Foundation

struct StandardReaderListsPage: Codable, Sendable {
    let lists: [StandardReaderList]
    let refreshedAt: String
    var creatorDid: String?
    var complete: Bool?

    func merging(previous: [StandardReaderList]) -> [StandardReaderList] {
        guard complete == false else { return lists }
        var merged = previous
        for list in lists {
            if let index = merged.firstIndex(where: { $0.uri == list.uri }) { merged[index] = list }
            else { merged.append(list) }
        }
        return merged
    }
}
