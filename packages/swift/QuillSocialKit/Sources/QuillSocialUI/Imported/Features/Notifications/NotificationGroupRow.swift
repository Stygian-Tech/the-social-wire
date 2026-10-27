#if os(iOS)
import Feeds
import SwiftUI

struct NotificationGroupRow: View {
    let group: NotificationsModel.NotificationGroup
    let postURI: String?
    let postPreview: TimelinePost?
    let contextURI: String?
    let contextPreview: TimelinePost?
    let isPostUnavailable: Bool
    let isContextUnavailable: Bool
    let onOpen: () -> Void
    let onOpenContext: () -> Void
    let onRetry: () -> Void
    let onShowActors: () -> Void
    let onOpenAuthor: (NotificationsModel.NotificationItem.Author) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            authorAvatars

            VStack(alignment: .leading, spacing: 8) {
                header
                if let postPreview {
                    NotificationPostPreviewView(post: postPreview, onOpen: onOpen)
                        .accessibilityIdentifier("notification-post-\(group.latest.reason)")
                } else if postURI != nil {
                    if let text = group.latest.record.text, !text.isEmpty {
                        Button(action: onOpen) {
                            Text(text).font(.subheadline).foregroundStyle(.primary)
                                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("notification-post-\(group.latest.reason)")
                    }
                    previewStatus(unavailable: isPostUnavailable)
                }

                if contextURI != nil {
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.secondary.opacity(0.25)).frame(width: 2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.latest.reason == "reply" ? "Replying To" : "Quoted Post")
                                .font(.caption).foregroundStyle(.tertiary)
                            if let contextPreview {
                                NotificationPostPreviewView(post: contextPreview, onOpen: onOpenContext)
                                    .accessibilityIdentifier("notification-context-\(group.latest.reason)")
                            } else if let quote = postPreview?.quote, quote.uri == contextURI {
                                NotificationPostPreviewView(quote: quote, onOpen: onOpenContext)
                                    .accessibilityIdentifier("notification-context-\(group.latest.reason)")
                            } else {
                                previewStatus(unavailable: isContextUnavailable)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("social-notification-\(group.latest.reason)")
    }

    private var authorAvatars: some View {
        let authors = Array(group.authors.prefix(2))
        return HStack(spacing: -12) {
            ForEach(Array(authors.enumerated()), id: \.element.did) { index, author in
                Button { onOpenAuthor(author) } label: {
                    AsyncImage(url: author.avatar) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable().foregroundStyle(.secondary)
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(.circle)
                    .overlay { Circle().stroke(.background, lineWidth: 2) }
                    .overlay(alignment: .bottomTrailing) {
                        if index == 0 {
                            Image(systemName: symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(symbolColor)
                                .padding(3)
                                .background(.background, in: .circle)
                                .offset(x: 3, y: 3)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 44, height: 44, alignment: .topLeading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open @\(author.handle) Profile")
                .accessibilityIdentifier("social-notification-avatar-\(group.latest.reason)-\(author.did)")
                .zIndex(Double(index))
            }
        }
        .frame(height: 44, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                if group.authors.count == 1 { onOpenAuthor(group.latest.author) }
                else { onShowActors() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Text(actorSummary).fontWeight(.semibold)) \(Text(message).foregroundColor(.secondary))")
                        .font(.subheadline).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if group.authors.count > 1 {
                        Image(systemName: "chevron.down")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(actorSummary) \(String(localized: message))")
            .accessibilityHint(group.authors.count == 1 ? "View Profile" : "Show People")
            .accessibilityIdentifier("social-notification-actors-\(group.latest.reason)")
            SocialTimestampView(date: group.latest.indexedAt)
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                .fixedSize()
            if !group.isRead {
                Circle().fill(.tint).frame(width: 6, height: 6)
                    .accessibilityLabel("Unread")
            }
        }
    }

    @ViewBuilder
    private func previewStatus(unavailable: Bool) -> some View {
        if unavailable {
            HStack(spacing: 8) {
                Text("Post Unavailable").foregroundStyle(.secondary)
                Button("Try Again", action: onRetry)
            }
            .font(.caption)
        } else {
            ProgressView("Loading Post")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actorSummary: String {
        let first = group.latest.author.displayName ?? group.latest.author.handle
        return group.authors.count > 1 ? "\(first) + \(group.authors.count - 1)" : first
    }

    private var message: LocalizedStringResource {
        switch group.latest.reason {
        case "like", "like-via-repost": "liked your post"
        case "repost", "repost-via-repost": "reposted your post"
        case "follow": "followed you"
        case "mention": "mentioned you"
        case "reply": "replied to you"
        case "quote": "quoted your post"
        case "verified": "verified your account"
        case "unverified": "removed your verification"
        case "starterpack-joined": "joined through your starter pack"
        case "subscribed-post": "posted to an account you subscribed to"
        case "contact-match": "is in your contacts"
        default: "interacted with you"
        }
    }

    private var symbol: String {
        switch group.latest.reason {
        case "like", "like-via-repost": "heart.fill"
        case "repost", "repost-via-repost": "arrow.2.squarepath"
        case "follow", "contact-match": "person.badge.plus"
        case "mention": "at"
        case "reply": "bubble.left.fill"
        case "quote": "quote.bubble.fill"
        case "verified", "unverified": "checkmark.seal.fill"
        case "starterpack-joined": "person.3.fill"
        case "subscribed-post": "bell.fill"
        default: "bell.fill"
        }
    }

    private var symbolColor: Color {
        switch group.latest.reason {
        case "like", "like-via-repost": .pink
        case "repost", "repost-via-repost", "quote": .green
        case "follow": .indigo
        case "contact-match", "verified": .blue
        case "mention", "reply": .accentColor
        case "unverified": .secondary
        default: .orange
        }
    }
}

#endif
