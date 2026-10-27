#if os(iOS)
import Feeds

struct AccountBadgeItem: Hashable, Identifiable {
    let id: String
    let title: String
    let sourceDID: String
}

#endif
