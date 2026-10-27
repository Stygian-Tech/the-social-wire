public struct PostThread: Sendable, Equatable {
    public let entries: [ThreadEntry]

    public init(entries: [ThreadEntry]) {
        self.entries = entries
    }

    public func displayItems(
        maximumReplyDepth: Int = 3,
        expandedParentIDs: Set<String> = []
    ) -> [ThreadDisplayItem] {
        var result: [ThreadDisplayItem] = []
        var cappedAncestor: ThreadEntry?
        var hiddenCounts: [String: Int] = [:]

        for entry in entries {
            if entry.depth <= maximumReplyDepth {
                cappedAncestor = entry.depth == maximumReplyDepth ? entry : nil
                result.append(.post(entry))
                continue
            }

            guard let ancestor = cappedAncestor else { continue }
            if expandedParentIDs.contains(ancestor.id) {
                result.append(.post(entry))
            } else {
                hiddenCounts[ancestor.id, default: 0] += 1
            }
        }

        guard !hiddenCounts.isEmpty else { return result }
        return result.flatMap { item in
            guard case .post(let entry) = item,
                  let hiddenCount = hiddenCounts[entry.id]
            else { return [item] }
            return [item, .showMore(parentID: entry.id, hiddenCount: hiddenCount)]
        }
    }
}
