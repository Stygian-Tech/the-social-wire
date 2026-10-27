#if os(iOS)
public enum QuillSocialDestination: String, CaseIterable, Hashable, Sendable {
    case timeline, explore, notifications, messages, bookmarks, lists, feeds
}
#endif
