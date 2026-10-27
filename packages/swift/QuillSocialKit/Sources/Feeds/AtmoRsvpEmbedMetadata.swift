import Foundation

public struct AtmoRsvpEmbedMetadata: Hashable, Sendable {
    public let eventURI: String
    public let eventCID: String
    public let name: String
    public let description: String?
    public let startsAt: Date?
    public let endsAt: Date?
    public let location: String?
    public let mutualAttendees: [AtmoRsvpAttendee]
    public let responseCount: Int
    public let viewerStatus: AtmoRsvpStatus?
    public let viewerRkey: String?

    public init(
        eventURI: String,
        eventCID: String,
        name: String,
        description: String?,
        startsAt: Date?,
        endsAt: Date?,
        location: String?,
        mutualAttendees: [AtmoRsvpAttendee],
        responseCount: Int,
        viewerStatus: AtmoRsvpStatus?,
        viewerRkey: String?
    ) {
        self.eventURI = eventURI
        self.eventCID = eventCID
        self.name = name
        self.description = description
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
        self.mutualAttendees = mutualAttendees
        self.responseCount = responseCount
        self.viewerStatus = viewerStatus
        self.viewerRkey = viewerRkey
    }
}
