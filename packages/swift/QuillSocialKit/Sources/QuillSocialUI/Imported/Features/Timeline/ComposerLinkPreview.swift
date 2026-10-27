#if os(iOS)
import Feeds

struct ComposerLinkPreview: Sendable {
    let embed: TimelineExternalEmbed
    let attachment: PostExternalAttachment
}

#endif
