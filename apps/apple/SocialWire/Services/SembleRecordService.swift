import Foundation

@MainActor
final class SembleRecordService {
    private let xrpc: XRPCClient

    init(xrpc: XRPCClient) {
        self.xrpc = xrpc
    }

    func saveURL(_ rawURL: String, title: String?, to collectionURI: String) async throws -> SembleSaveOutcome {
        guard let normalizedURL = Self.normalizeURL(rawURL) else { throw SocialWireError.invalidURL }
        let card = try await findOrCreateURLCard(normalizedURL)
        do {
            try await addCard(card, to: collectionURI)
            return .saved(card: card)
        } catch {
            return .membershipRetry(
                SembleSaveRetryState(
                    collectionURI: collectionURI,
                    card: card,
                    normalizedURL: normalizedURL,
                    title: title
                ),
                message: error.localizedDescription
            )
        }
    }

    func resumeSave(_ state: SembleSaveRetryState) async throws {
        try await addCard(state.card, to: state.collectionURI)
    }

    func addCard(_ card: StrongRef, to collectionURI: String) async throws {
        let collection = try await strongRef(for: collectionURI)
        if try await viewerAlreadyLinked(cardURI: card.uri, collectionURI: collectionURI) { return }
        let viewerDID = try await xrpc.currentDID()
        let now = DateFormatters.string()
        _ = try await xrpc.createRecordReference(
            collection: SembleRecordCollection.collectionLink,
            record: SembleCollectionLinkRecord(
                type: SembleRecordCollection.collectionLink,
                collection: collection,
                card: card,
                addedBy: viewerDID,
                addedAt: now,
                createdAt: now
            )
        )
    }

    func removeMembership(item: SembleCollectionItem, collectionURI: String) async throws {
        let viewerDID = try await xrpc.currentDID()
        guard item.unlinkAvailable,
              let membership = item.membership,
              let linkURI = membership.linkUri,
              let linkATURI = ATURI(linkURI)
        else {
            throw SocialWireError.badResponse("This Semble row does not expose a removable collection membership.")
        }
        if linkATURI.repo == viewerDID {
            try await xrpc.deleteRecord(collection: SembleRecordCollection.collectionLink, rkey: linkATURI.rkey)
            return
        }

        guard ATURI(collectionURI)?.repo == viewerDID else {
            throw SocialWireError.badResponse("Only the collection owner can remove another contributor's membership.")
        }
        guard let linkCID = membership.linkCid, !linkCID.isEmpty else {
            throw SocialWireError.badResponse("This Semble membership is missing the CID required for removal.")
        }
        let now = DateFormatters.string()
        _ = try await xrpc.createRecordReference(
            collection: SembleRecordCollection.collectionLinkRemoval,
            record: SembleCollectionLinkRemovalRecord(
                type: SembleRecordCollection.collectionLinkRemoval,
                collection: try await strongRef(for: collectionURI),
                removedLink: StrongRef(uri: linkURI, cid: linkCID),
                removedAt: now
            )
        )
    }

    @discardableResult
    func addNote(_ text: String, to card: StrongRef) async throws -> StrongRef {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SocialWireError.badResponse("A note cannot be empty.") }
        return try await xrpc.createRecordReference(
            collection: SembleRecordCollection.card,
            record: SembleCardRecord.note(trimmed, parentCard: card, createdAt: DateFormatters.string())
        )
    }

    func updateNote(uri: String, text: String, parentCard: StrongRef) async throws {
        guard let noteATURI = ATURI(uri), noteATURI.repo == (try await xrpc.currentDID()) else {
            throw SocialWireError.badResponse("Only your own Semble notes can be edited.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SocialWireError.badResponse("A note cannot be empty.") }
        try await xrpc.putRecord(
            collection: SembleRecordCollection.card,
            rkey: noteATURI.rkey,
            record: SembleCardRecord.note(trimmed, parentCard: parentCard, createdAt: DateFormatters.string())
        )
    }

    @discardableResult
    func createConnection(
        source: String,
        target: String,
        connectionType: String?,
        note: String?
    ) async throws -> StrongRef {
        let now = DateFormatters.string()
        return try await xrpc.createRecordReference(
            collection: SembleRecordCollection.connection,
            record: SembleConnectionRecord(
                type: SembleRecordCollection.connection,
                source: source,
                target: target,
                connectionType: Self.nilIfEmpty(connectionType),
                note: Self.nilIfEmpty(note),
                createdAt: now,
                updatedAt: now
            )
        )
    }

    func updateConnection(
        uri: String,
        source: String,
        target: String,
        connectionType: String?,
        note: String?,
        createdAt: String
    ) async throws {
        guard let atURI = ATURI(uri), atURI.repo == (try await xrpc.currentDID()) else {
            throw SocialWireError.badResponse("Only your own Semble connections can be edited.")
        }
        try await xrpc.putRecord(
            collection: SembleRecordCollection.connection,
            rkey: atURI.rkey,
            record: SembleConnectionRecord(
                type: SembleRecordCollection.connection,
                source: source,
                target: target,
                connectionType: Self.nilIfEmpty(connectionType),
                note: Self.nilIfEmpty(note),
                createdAt: createdAt,
                updatedAt: DateFormatters.string()
            )
        )
    }

    func deleteConnection(uri: String) async throws {
        guard let atURI = ATURI(uri), atURI.repo == (try await xrpc.currentDID()) else {
            throw SocialWireError.badResponse("Only your own Semble connections can be deleted.")
        }
        try await xrpc.deleteRecord(collection: SembleRecordCollection.connection, rkey: atURI.rkey)
    }

    nonisolated static func normalizeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.url?.absoluteString
    }

    private func findOrCreateURLCard(_ normalizedURL: String) async throws -> StrongRef {
        var cursor: String?
        repeat {
            let page = try await xrpc.listAuthorizedGenericRecords(
                collection: SembleRecordCollection.card,
                cursor: cursor
            )
            if let existing = page.records.first(where: { Self.cardURL(in: $0.value) == normalizedURL }),
               let cid = existing.cid
            {
                return StrongRef(uri: existing.uri, cid: cid)
            }
            cursor = page.cursor
        } while cursor != nil

        return try await xrpc.createRecordReference(
            collection: SembleRecordCollection.card,
            record: SembleCardRecord.url(normalizedURL, createdAt: DateFormatters.string())
        )
    }

    private func viewerAlreadyLinked(cardURI: String, collectionURI: String) async throws -> Bool {
        var cursor: String?
        repeat {
            let page = try await xrpc.listAuthorizedGenericRecords(
                collection: SembleRecordCollection.collectionLink,
                cursor: cursor
            )
            if page.records.contains(where: { record in
                guard let object = record.value.object else { return false }
                return object["collection"]?.object?["uri"]?.string == collectionURI
                    && object["card"]?.object?["uri"]?.string == cardURI
            }) {
                return true
            }
            cursor = page.cursor
        } while cursor != nil
        return false
    }

    private func strongRef(for uri: String) async throws -> StrongRef {
        guard let atURI = ATURI(uri) else { throw SocialWireError.invalidATURI }
        let record = try await xrpc.getGenericRecord(
            repo: atURI.repo,
            collection: atURI.collection,
            rkey: atURI.rkey
        )
        guard let cid = record.cid, !cid.isEmpty else {
            throw SocialWireError.badResponse("The Semble record is missing a CID.")
        }
        return StrongRef(uri: record.uri, cid: cid)
    }

    nonisolated private static func cardURL(in value: JSONValue) -> String? {
        guard let object = value.object else { return nil }
        let raw = object["content"]?.object?["url"]?.string ?? object["url"]?.string
        return raw.flatMap(normalizeURL)
    }

    nonisolated private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
