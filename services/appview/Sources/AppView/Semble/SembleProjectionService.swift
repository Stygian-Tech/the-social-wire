import Foundation

struct SembleProjectionService: Sendable {
  private static let collectionPath = "/network.cosmik.collection.getByAtUri"
  private static let collectionsPath = "/network.cosmik.collection.listByUser"
  private static let connectionsPath = "/network.cosmik.connection.getForUrl"
  private static let cardCollection = "network.cosmik.card"
  private static let collectionLinkCollection = "network.cosmik.collectionLink"
  private static let connectionCollection = "network.cosmik.connection"
  private static let enrichmentConcurrency = 8

  let transport: any SembleProjectionTransport
  let recordReader: any SemblePublicRecordReading

  func collections(
    viewerDid: String,
    cursor: String?,
    limit: Int
  ) async throws -> SembleCollectionsResponseDTO {
    let page = try page(from: cursor)
    let upstream: SembleUpstreamCollectionsPage = try await get(
      path: Self.collectionsPath,
      query: [
        URLQueryItem(name: "identifier", value: viewerDid),
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "limit", value: String(limit)),
        URLQueryItem(name: "sortBy", value: "updatedAt"),
        URLQueryItem(name: "sortOrder", value: "desc"),
      ]
    )
    let collections = try upstream.collections.map { collection in
      guard let uri = collection.uri,
        let parsed = SembleAtUri.parse(uri),
        parsed.collection == "network.cosmik.collection",
        parsed.did == viewerDid,
        collection.author.id == viewerDid
      else {
        throw SembleProjectionError.upstream(
          "Semble returned a collection outside the authenticated viewer's repository."
        )
      }
      return Self.collectionDTO(collection, uri: uri)
    }
    return SembleCollectionsResponseDTO(
      collections: collections,
      cursor: SembleCursor.encode(
        nextPage: upstream.pagination.hasMore ? upstream.pagination.currentPage + 1 : nil
      )
    )
  }

  func collection(
    viewerDid: String,
    collectionUri: String,
    cursor: String?,
    limit: Int
  ) async throws -> SembleCollectionPageResponseDTO {
    guard let requested = SembleAtUri.parse(collectionUri),
      requested.collection == "network.cosmik.collection"
    else { throw SembleProjectionError.invalid("`collectionUri` must identify a Semble collection.") }
    guard requested.did == viewerDid else { throw SembleProjectionError.forbidden }
    let page = try page(from: cursor)
    let upstream: SembleUpstreamCollectionPage = try await get(
      path: Self.collectionPath,
      query: [
        URLQueryItem(name: "handle", value: requested.did),
        URLQueryItem(name: "recordKey", value: requested.rkey),
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "limit", value: String(limit)),
        URLQueryItem(name: "sortBy", value: "updatedAt"),
        URLQueryItem(name: "sortOrder", value: "desc"),
      ],
      notFound: true
    )
    guard upstream.uri == collectionUri, upstream.author.id == viewerDid else {
      throw SembleProjectionError.upstream(
        "Semble returned a collection that does not match the configured AT URI."
      )
    }

    var recordOwnerDids = Set(upstream.urlCards.map(\.author.id).filter { $0.hasPrefix("did:") })
    // A collection link is normally authored in the collection owner's repo even
    // when the linked card belongs to another contributor.
    recordOwnerDids.insert(viewerDid)
    let needsNotes = upstream.urlCards.contains { $0.note != nil }
    let recordCollections = needsNotes
      ? [Self.collectionLinkCollection, Self.cardCollection]
      : [Self.collectionLinkCollection]
    let enrichment = await records(for: recordOwnerDids, collections: recordCollections)
    let decoder = JSONDecoder()
    let links = enrichment.records.compactMap { record -> (SemblePublicRecord, SemblePDSCollectionLinkValue)? in
      guard record.collection == Self.collectionLinkCollection,
        let value = try? decoder.decode(SemblePDSCollectionLinkValue.self, from: record.value)
      else { return nil }
      return (record, value)
    }
    let cards = enrichment.records.compactMap { record -> (SemblePublicRecord, SemblePDSCardValue)? in
      guard record.collection == Self.cardCollection,
        let value = try? decoder.decode(SemblePDSCardValue.self, from: record.value)
      else { return nil }
      return (record, value)
    }

    var membershipComplete = enrichment.complete
    var recordLinksComplete = enrichment.complete
    let items = try upstream.urlCards.map { card -> SembleCollectionItemDTO in
      guard let cardUri = card.uri, SembleAtUri.parse(cardUri) != nil else {
        throw SembleProjectionError.upstream("Semble returned a card without an AT URI.")
      }
      guard let cardType = SembleCardTypeDTO(rawValue: card.type) else {
        throw SembleProjectionError.upstream("Semble returned an unsupported card type.")
      }
      let matchedLink = links.first { _, link in
        link.collection.uri == collectionUri
          && (link.card.uri == cardUri || link.originalCard?.uri == cardUri)
      }
      let membership: SembleMembershipDTO?
      if let (record, link) = matchedLink, let linkOwner = SembleAtUri.parse(record.uri)?.did {
        membership = SembleMembershipDTO(
          linkUri: record.uri,
          linkCid: record.cid,
          authorDid: linkOwner,
          addedBy: link.addedBy,
          addedAt: link.addedAt,
          viewerOwned: linkOwner == viewerDid
        )
      } else {
        membership = nil
        membershipComplete = false
        recordLinksComplete = false
      }

      let contributor = SembleContributorDTO(
        did: card.author.id,
        handle: card.author.handle,
        displayName: card.author.name,
        avatar: card.author.avatarUrl
      )
      let matchedCard = enrichment.records.first { $0.uri == cardUri }
      let note: SembleNoteDTO?
      if let upstreamNote = card.note {
        let matchedNote = cards.first { record, value in
          value.type == SembleCardTypeDTO.note.rawValue
            && value.parentCard?.uri == cardUri
            && value.content?.text == upstreamNote.text
            && SembleAtUri.parse(record.uri) != nil
        }
        if let (record, _) = matchedNote, let noteOwner = SembleAtUri.parse(record.uri)?.did {
          note = SembleNoteDTO(
            uri: record.uri,
            text: upstreamNote.text,
            authorDid: noteOwner,
            editable: noteOwner == viewerDid
          )
        } else {
          note = SembleNoteDTO(
            uri: nil,
            text: upstreamNote.text,
            authorDid: card.author.id,
            editable: false
          )
          recordLinksComplete = false
        }
      } else {
        note = nil
      }
      return SembleCollectionItemDTO(
        id: card.id,
        cardUri: cardUri,
        cardCid: card.cid ?? matchedCard?.cid,
        cardType: cardType,
        url: card.url ?? card.cardContent?.url,
        title: card.cardContent?.title,
        description: card.cardContent?.description,
        image: card.cardContent?.imageUrl,
        siteName: card.cardContent?.siteName,
        publishedAt: card.cardContent?.publishedDate,
        createdAt: card.createdAt,
        membership: membership,
        unlinkAvailable: membership != nil,
        contributor: contributor,
        note: note
      )
    }

    return SembleCollectionPageResponseDTO(
      collection: SembleCollectionDTO(
        uri: collectionUri,
        name: upstream.name,
        description: upstream.description,
        accessType: upstream.accessType,
        cardCount: upstream.cardCount,
        createdAt: upstream.createdAt,
        updatedAt: upstream.updatedAt
      ),
      items: items,
      cursor: SembleCursor.encode(
        nextPage: upstream.pagination.hasMore ? upstream.pagination.currentPage + 1 : nil
      ),
      membershipComplete: membershipComplete,
      recordLinksComplete: recordLinksComplete
    )
  }

  func connections(
    viewerDid: String,
    url: String,
    cursor: String?,
    limit: Int
  ) async throws -> SembleConnectionsResponseDTO {
    guard let parsedURL = URL(string: url),
      ["http", "https"].contains(parsedURL.scheme?.lowercased() ?? ""),
      parsedURL.host != nil
    else { throw SembleProjectionError.invalid("`url` must be an absolute HTTP(S) URL.") }
    let page = try page(from: cursor)
    let upstream: SembleUpstreamConnectionsPage = try await get(
      path: Self.connectionsPath,
      query: [
        URLQueryItem(name: "url", value: url),
        URLQueryItem(name: "direction", value: "both"),
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "limit", value: String(limit)),
        URLQueryItem(name: "sortBy", value: "createdAt"),
        URLQueryItem(name: "sortOrder", value: "desc"),
      ]
    )
    let authors = Set(upstream.connections.map(\.connection.curator.id).filter { $0.hasPrefix("did:") })
    let enrichment = await records(for: authors, collections: [Self.connectionCollection])
    let decoder = JSONDecoder()
    let records = enrichment.records.compactMap { record -> (SemblePublicRecord, SemblePDSConnectionValue)? in
      guard let value = try? decoder.decode(SemblePDSConnectionValue.self, from: record.value) else {
        return nil
      }
      return (record, value)
    }
    var recordLinksComplete = enrichment.complete
    let connections = upstream.connections.map { upstreamConnection in
      let value = upstreamConnection.connection
      let matched = records.first { record, candidate in
        guard SembleAtUri.parse(record.uri)?.did == value.curator.id else { return false }
        return candidate.source == upstreamConnection.source.url
          && candidate.target == upstreamConnection.target.url
          && candidate.connectionType == value.type
          && candidate.note == value.note
      }
      // The Semble projection's database identifier (and any future URI-shaped field)
      // is not proof of a PDS record. Only surface an AT URI after exact public-PDS
      // record matching so clients never target an unverified mutation record.
      let uri = matched?.0.uri
      let owner = uri.flatMap { SembleAtUri.parse($0)?.did }
      if uri == nil { recordLinksComplete = false }
      return SembleConnectionDTO(
        uri: uri,
        source: upstreamConnection.source.url,
        target: upstreamConnection.target.url,
        connectionType: value.type,
        note: value.note,
        createdAt: value.createdAt,
        updatedAt: value.updatedAt,
        authorDid: value.curator.id,
        editable: owner == viewerDid
      )
    }
    return SembleConnectionsResponseDTO(
      connections: connections,
      cursor: SembleCursor.encode(
        nextPage: upstream.pagination.hasMore ? upstream.pagination.currentPage + 1 : nil
      ),
      recordLinksComplete: recordLinksComplete
    )
  }

  private func page(from cursor: String?) throws -> Int {
    guard let page = SembleCursor.decode(cursor) else {
      throw SembleProjectionError.invalid("`cursor` is invalid.")
    }
    return page
  }

  private func get<T: Decodable>(
    path: String,
    query: [URLQueryItem],
    notFound: Bool = false
  ) async throws -> T {
    let response: SembleProjectionTransportResponse
    do {
      response = try await transport.get(path: path, query: query)
    } catch let error as SembleProjectionError {
      throw error
    } catch {
      throw SembleProjectionError.upstream("Semble public projection is unavailable.")
    }
    if notFound, response.statusCode == 404 { throw SembleProjectionError.notFound }
    guard response.statusCode == 200 else {
      throw SembleProjectionError.upstream(
        "Semble public projection failed with status \(response.statusCode)."
      )
    }
    do {
      return try JSONDecoder().decode(T.self, from: response.body)
    } catch {
      throw SembleProjectionError.upstream("Semble public projection returned an invalid response.")
    }
  }

  private static func collectionDTO(
    _ collection: SembleUpstreamCollection,
    uri: String
  ) -> SembleCollectionDTO {
    SembleCollectionDTO(
      uri: uri,
      name: collection.name,
      description: collection.description,
      accessType: collection.accessType,
      cardCount: collection.cardCount,
      createdAt: collection.createdAt,
      updatedAt: collection.updatedAt
    )
  }

  private struct RecordBundle: Sendable {
    let records: [SemblePublicRecord]
    let complete: Bool
  }

  private func records(
    for dids: Set<String>,
    collections: [String]
  ) async -> RecordBundle {
    let authors = dids.sorted()
    guard !authors.isEmpty else { return RecordBundle(records: [], complete: true) }
    return await withTaskGroup(of: RecordBundle.self) { group in
      var next = 0
      var all: [SemblePublicRecord] = []
      var complete = true
      func add(_ did: String) {
        group.addTask {
          do {
            let read = try await recordReader.read(repoDid: did, collections: collections)
            return RecordBundle(records: read.records, complete: read.complete)
          } catch {
            return RecordBundle(records: [], complete: false)
          }
        }
      }
      while next < min(Self.enrichmentConcurrency, authors.count) {
        add(authors[next])
        next += 1
      }
      while let bundle = await group.next() {
        all.append(contentsOf: bundle.records)
        complete = complete && bundle.complete
        if next < authors.count {
          add(authors[next])
          next += 1
        }
      }
      return RecordBundle(records: all, complete: complete)
    }
  }
}
