#if os(iOS)
import Feeds
import SwiftUI

struct AtmoRsvpEmbedView: View {
    let metadata: AtmoRsvpEmbedMetadata
    let destination: URL
    let thumbnailURL: URL?

    @Environment(AppServices.self) private var services
    @State private var status: AtmoRsvpStatus?
    @State private var rkey: String?
    @State private var isUpdating = false
    @State private var feedbackGeneration = 0

    init(metadata: AtmoRsvpEmbedMetadata, destination: URL, thumbnailURL: URL?) {
        self.metadata = metadata
        self.destination = destination
        self.thumbnailURL = thumbnailURL
        _status = State(initialValue: metadata.viewerStatus)
        _rkey = State(initialValue: metadata.viewerRkey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: destination) {
                VStack(alignment: .leading, spacing: 9) {
                    if let thumbnailURL {
                        FeedMediaViewport(aspectRatio: 1.91, cornerRadius: 8) {
                            AsyncImage(url: thumbnailURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(.fill.tertiary)
                            }
                        }
                    }

                    Text(metadata.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let startsAt = metadata.startsAt {
                        Label {
                            Text(startsAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        } icon: {
                            Image(systemName: "calendar")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let location = metadata.location {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let description = metadata.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if !metadata.mutualAttendees.isEmpty {
                        HStack(spacing: 8) {
                            HStack(spacing: -8) {
                                ForEach(metadata.mutualAttendees.prefix(5)) { attendee in
                                    AsyncImage(url: attendee.avatarURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "person.circle.fill").foregroundStyle(.gray)
                                    }
                                    .frame(width: 26, height: 26)
                                    .background(.background, in: .circle)
                                    .clipShape(.circle)
                                    .overlay { Circle().stroke(.background, lineWidth: 2) }
                                    .accessibilityLabel(attendee.displayName ?? "Mutual attendee")
                                }
                            }

                            Text(followingResponseLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5) }
                .clipShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button {
                    update(.going)
                } label: {
                    HStack(spacing: 6) {
                        Text("Going")
                        Spacer(minLength: 4)
                        Image(systemName: status == .going ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)

                Button {
                    update(.interested)
                } label: {
                    HStack(spacing: 6) {
                        Text("Interested")
                        Spacer(minLength: 4)
                        Image(systemName: status == .interested ? "star.fill" : "star")
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ThemeChipButtonStyle())
            .disabled(isUpdating)
        }
        .sensoryFeedback(.selection, trigger: feedbackGeneration)
    }

    private var followingResponseLabel: String {
        let count = metadata.mutualAttendees.count
        return count == 1 ? "1 person you follow responded" : "\(count) people you follow responded"
    }

    private func update(_ target: AtmoRsvpStatus) {
        guard !isUpdating else { return }
        isUpdating = true
        let next: AtmoRsvpStatus? = status == target ? nil : target
        let previousStatus = status
        let previousRkey = rkey
        status = next
        Task {
            defer { isUpdating = false }
            do {
                let updatedRkey = try await services.updateEventRsvp(
                    metadata.eventURI,
                    metadata.eventCID,
                    next,
                    rkey
                )
                rkey = updatedRkey
                feedbackGeneration += 1
            } catch {
                status = previousStatus
                rkey = previousRkey
            }
        }
    }
}

#endif
