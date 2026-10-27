#if os(iOS)
enum ProfileSettingsSheet: String, Identifiable {
    case contentProvider
    case moderation
    case trustedVerifiers

    var id: String { rawValue }
}

#endif
