#if os(iOS)
import Feeds
import Foundation

actor AtmoRsvpMetadataCache {
    typealias SessionDID = @Sendable () async throws -> String
    typealias Follows = @Sendable (_ actor: String, _ cursor: String?) async throws -> Data

    private let sessionDID: SessionDID
    private let follows: Follows
    private var values: [URL: AtmoRsvpEmbedMetadata] = [:]
    private var followedDIDs: Set<String>?

    init(sessionDID: @escaping SessionDID, follows: @escaping Follows) {
        self.sessionDID = sessionDID
        self.follows = follows
    }

    func metadata(for url: URL) async -> AtmoRsvpEmbedMetadata? {
        if let value = values[url] { return value }
        guard let reference = eventReference(from: url),
              let did = try? await ATProtoPublicRepository.resolveDID(for: reference.actor) else {
            return nil
        }
        let eventURI = "at://\(did)/community.lexicon.calendar.event/\(reference.rkey)"
        guard let event = await event(uri: eventURI) else { return nil }
        let viewerDID = try? await sessionDID()
        let followed = await loadFollowedDIDs(viewerDID: viewerDID)
        let ownRsvp: ViewerRsvp?
        if let viewerDID {
            ownRsvp = await viewerRsvp(actor: viewerDID, eventURI: eventURI)
        } else {
            ownRsvp = nil
        }
        let attendees = await attendees(eventURI: eventURI).filter { followed.contains($0.did) }
        let metadata = AtmoRsvpEmbedMetadata(
            eventURI: eventURI,
            eventCID: event.cid,
            name: event.name,
            description: event.description,
            startsAt: event.startsAt,
            endsAt: event.endsAt,
            location: event.location,
            mutualAttendees: attendees,
            responseCount: event.responseCount,
            viewerStatus: ownRsvp?.status,
            viewerRkey: ownRsvp?.rkey
        )
        values[url] = metadata
        return metadata
    }

    func update(
        eventURI: String,
        status: AtmoRsvpStatus?,
        rkey: String?
    ) {
        for (url, current) in values where current.eventURI == eventURI {
            values[url] = AtmoRsvpEmbedMetadata(
                eventURI: current.eventURI,
                eventCID: current.eventCID,
                name: current.name,
                description: current.description,
                startsAt: current.startsAt,
                endsAt: current.endsAt,
                location: current.location,
                mutualAttendees: current.mutualAttendees,
                responseCount: current.responseCount,
                viewerStatus: status,
                viewerRkey: rkey
            )
        }
    }

    func notifyUpdate(uri: String) async {
        guard let url = URL(string: "https://atmo.rsvp/xrpc/rsvp.atmo.notifyOfUpdate"),
              let body = try? JSONSerialization.data(withJSONObject: ["uri": uri]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request)
    }

    private func loadFollowedDIDs(viewerDID: String?) async -> Set<String> {
        if let followedDIDs { return followedDIDs }
        guard let viewerDID else { return [] }
        var result = Set<String>()
        var cursor: String?
        repeat {
            guard let data = try? await follows(viewerDID, cursor),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                break
            }
            for follow in object["follows"] as? [[String: Any]] ?? [] {
                if let did = follow["did"] as? String { result.insert(did) }
            }
            cursor = object["cursor"] as? String
        } while cursor != nil
        followedDIDs = result
        return result
    }

    private func eventReference(from url: URL) -> (actor: String, rkey: String)? {
        let parts = url.pathComponents
        guard parts.count >= 5, parts[1] == "p", parts[3] == "e",
              let actor = parts[2].removingPercentEncoding else { return nil }
        return (actor, parts[4])
    }

    /// Provider arrays can repeat a DID. Keep the first profile without trapping on duplicates.
    nonisolated static func profilesByDID(_ profiles: [[String: Any]]) -> [String: [String: Any]] {
        Dictionary(profiles.compactMap { profile -> (String, [String: Any])? in
            guard let did = profile["did"] as? String, !did.isEmpty else { return nil }
            return (did, profile)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func event(uri: String) async -> Event? {
        guard let data = await atmo(
            method: "rsvp.atmo.event.getRecord",
            parameters: ["uri": uri, "hydrateRsvps": "12", "profiles": "true"]
        ), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cid = object["cid"] as? String,
              let value = object["value"] as? [String: Any],
              let name = value["name"] as? String else { return nil }

        let profiles = Self.profilesByDID(object["profiles"] as? [[String: Any]] ?? [])
        let rsvps = object["rsvps"] as? [String: [[String: Any]]] ?? [:]
        var attendees: [AtmoRsvpAttendee] = []
        for status in [AtmoRsvpStatus.going, .interested] {
            let token = "community.lexicon.calendar.rsvp#\(status.rawValue)"
            for response in rsvps[token] ?? [] {
                guard let did = response["did"] as? String,
                      let profile = profiles[did] else { continue }
                let profileValue = profile["value"] as? [String: Any]
                let avatar = profileValue?["avatar"] as? [String: Any]
                let reference = avatar?["ref"] as? [String: Any]
                let cid = reference?["$link"] as? String
                attendees.append(.init(
                    did: did,
                    displayName: profileValue?["displayName"] as? String ?? profile["handle"] as? String,
                    avatarURL: cid.flatMap {
                        URL(string: "https://cdn.bsky.app/img/avatar_thumbnail/plain/\(did)/\($0)@jpeg")
                    },
                    status: status
                ))
            }
        }
        return Event(
            cid: cid,
            name: name,
            description: value["description"] as? String,
            startsAt: date(value["startsAt"]),
            endsAt: date(value["endsAt"]),
            location: location(value["locations"]),
            attendees: attendees,
            responseCount: object["rsvpsCount"] as? Int ?? attendees.count
        )
    }

    private func viewerRsvp(actor: String, eventURI: String) async -> ViewerRsvp? {
        guard let data = await atmo(
            method: "rsvp.atmo.rsvp.listRecords",
            parameters: ["actor": actor, "subjectUri": eventURI]
        ), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = (object["records"] as? [[String: Any]])?.first,
              let uri = record["uri"] as? String,
              let value = record["value"] as? [String: Any],
              let token = value["status"] as? String,
              let status = AtmoRsvpStatus(rawValue: String(token.split(separator: "#").last ?? "")) else {
            return nil
        }
        return ViewerRsvp(status: status, rkey: uri.split(separator: "/").last.map(String.init))
    }

    private func attendees(eventURI: String) async -> [AtmoRsvpAttendee] {
        var result: [AtmoRsvpAttendee] = []
        var seen = Set<String>()
        for status in [AtmoRsvpStatus.going, .interested] {
            let token = "community.lexicon.calendar.rsvp#\(status.rawValue)"
            guard let data = await atmo(
                method: "rsvp.atmo.rsvp.listRecords",
                parameters: [
                    "subjectUri": eventURI,
                    "status": token,
                    "profiles": "true",
                    "limit": "200",
                ]
            ), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let profiles = Self.profilesByDID(object["profiles"] as? [[String: Any]] ?? [])
            for record in object["records"] as? [[String: Any]] ?? [] {
                guard let did = record["did"] as? String, seen.insert(did).inserted else { continue }
                let profile = profiles[did]
                let profileValue = profile?["value"] as? [String: Any]
                let avatar = profileValue?["avatar"] as? [String: Any]
                let reference = avatar?["ref"] as? [String: Any]
                let cid = reference?["$link"] as? String
                result.append(.init(
                    did: did,
                    displayName: profileValue?["displayName"] as? String ?? profile?["handle"] as? String,
                    avatarURL: cid.flatMap {
                        URL(string: "https://cdn.bsky.app/img/avatar_thumbnail/plain/\(did)/\($0)@jpeg")
                    },
                    status: status
                ))
            }
        }
        return result
    }

    private func atmo(method: String, parameters: [String: String]) async -> Data? {
        var components = URLComponents(string: "https://atmo.rsvp/xrpc/\(method)")!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { return nil }
        return data
    }

    private func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { try? Date($0, strategy: .iso8601) }
    }

    private func location(_ value: Any?) -> String? {
        guard let location = (value as? [[String: Any]])?.first else { return nil }
        let pieces = ["name", "street", "locality", "region", "country"]
            .compactMap { location[$0] as? String }
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? nil : pieces.joined(separator: ", ")
    }

    private struct Event {
        let cid: String
        let name: String
        let description: String?
        let startsAt: Date?
        let endsAt: Date?
        let location: String?
        let attendees: [AtmoRsvpAttendee]
        let responseCount: Int
    }

    private struct ViewerRsvp {
        let status: AtmoRsvpStatus
        let rkey: String?
    }
}

#endif
