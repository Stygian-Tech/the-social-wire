#if os(iOS)
import Feeds
import SwiftUI

struct ThreadEntriesView: View {
    let thread: PostThread

    @State private var expandedParentIDs: Set<String> = []
    @State private var didSetInitialPosition = false

    var body: some View {
        let positions = Self.authoredThreadPositions(in: thread)

        ScrollViewReader { proxy in
            List {
                ForEach(thread.displayItems(expandedParentIDs: expandedParentIDs)) { item in
                    switch item {
                    case .post(let entry):
                        ThreadPostRow(
                            entry: entry,
                            threadPosition: positions[entry.id]
                        )
                            .listRowInsets(rowInsets(for: entry))
                            .listRowBackground(Color.clear)
                    case .showMore(let parentID, let hiddenCount):
                        ShowMoreRepliesChip(hiddenCount: hiddenCount) {
                            expandedParentIDs.insert(parentID)
                        }
                        .listRowInsets(
                            EdgeInsets(top: 4, leading: 46, bottom: 8, trailing: 16)
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .task(id: focusedID) {
                guard !didSetInitialPosition, let focusedID else { return }
                didSetInitialPosition = true
                await Task.yield()
                proxy.scrollTo("post:\(focusedID)", anchor: .top)
            }
        }
    }

    private var focusedID: String? {
        thread.entries.first(where: \.isFocused)?.id
    }

    static func authoredThreadPositions(
        in thread: PostThread
    ) -> [String: (position: Int, total: Int)] {
        guard let root = thread.entries.first else { return [:] }
        let authoredPrefix = thread.entries.prefix { entry in
            entry.post.uri == root.post.uri || (
                entry.post.author.did == root.post.author.did
                    && entry.replyingTo?.did == root.post.author.did
            )
        }
        guard authoredPrefix.count > 1 else { return [:] }
        return Dictionary(uniqueKeysWithValues: authoredPrefix.enumerated().map {
            ($0.element.id, (position: $0.offset + 1, total: authoredPrefix.count))
        })
    }

    private func rowInsets(for entry: ThreadEntry) -> EdgeInsets {
        let replyDepth = min(max(entry.depth, 0), 3)
        return EdgeInsets(
            top: 6,
            leading: 16 + CGFloat(replyDepth) * 10,
            bottom: 6,
            trailing: 16
        )
    }
}

#endif
