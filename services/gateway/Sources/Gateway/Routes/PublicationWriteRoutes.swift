import Foundation
import GatewayCore
import Hummingbird
import ThinAppViewCore

struct PublicationWriteRoutes {
  let repo: ATProtoAuthenticatedRepoClient

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.post("/v1/publications/folders") { request, context async throws -> GatewayRecordWriteResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: CreateFolderRequest.self, context: context)
      let now = iso8601Now()
      var record: [String: Any] = [
        "$type": PublicationLexicons.folder,
        "name": body.name,
        "sortOrder": body.sortOrder ?? 0,
        "createdAt": now,
      ]
      if let icon = body.icon { record["icon"] = icon }
      if let iconImage = body.iconImage { record["iconImage"] = iconImage }
      guard let uri = try await repo.createRecord(
        auth: auth,
        collection: PublicationLexicons.folder,
        record: record
      ) else {
        throw HTTPError(.badGateway, message: "Folder create did not return uri")
      }
      return GatewayRecordWriteResponse(uri: uri, rkey: rkeyFromUri(uri) ?? uri)
    }

    group.put("/v1/publications/folders/:rkey") { request, context async throws -> HTTPResponse.Status in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let rkey = context.coreContext.parameters.get("rkey") else {
        throw HTTPError(.badRequest, message: "Missing rkey")
      }
      let body = try await request.decode(as: UpdateFolderRequest.self, context: context)
      let existing = try await repo.getRecord(
        auth: auth,
        repo: auth.did,
        collection: PublicationLexicons.folder,
        rkey: rkey
      )
      var record = existing?.values ?? [
        "$type": PublicationLexicons.folder,
        "createdAt": iso8601Now(),
      ]
      record["$type"] = PublicationLexicons.folder
      if let name = body.name { record["name"] = name }
      if let sortOrder = body.sortOrder { record["sortOrder"] = sortOrder }
      if let icon = body.icon { record["icon"] = icon }
      if let iconImage = body.iconImage { record["iconImage"] = iconImage }
      try await repo.putRecord(
        auth: auth,
        collection: PublicationLexicons.folder,
        rkey: rkey,
        record: record
      )
      return .ok
    }

    group.delete("/v1/publications/folders/:rkey") { _, context async throws -> HTTPResponse.Status in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let rkey = context.coreContext.parameters.get("rkey") else {
        throw HTTPError(.badRequest, message: "Missing rkey")
      }
      try await repo.deleteRecord(auth: auth, collection: PublicationLexicons.folder, rkey: rkey)
      return .ok
    }

    group.put("/v1/publications/prefs") { request, context async throws -> GatewayRecordWriteResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: UpsertPublicationPrefsRequest.self, context: context)
      let rkey = body.rkey ?? body.existingRkey ?? DeterministicKeys.generateTID()
      let now = iso8601Now()
      try await repo.putRecord(
        auth: auth,
        collection: PublicationLexicons.publicationPrefs,
        rkey: rkey,
        record: [
          "$type": PublicationLexicons.publicationPrefs,
          "publicationId": body.publicationId,
          "folderId": body.folderId as Any,
          "sortOrder": body.sortOrder ?? 0,
          "hidden": body.hidden ?? false,
          "createdAt": body.createdAt ?? now,
        ]
      )
      let uri = "at://\(auth.did)/\(PublicationLexicons.publicationPrefs)/\(rkey)"
      return GatewayRecordWriteResponse(uri: uri, rkey: rkey)
    }

    group.post("/v1/publications/subscriptions") { request, context async throws -> GatewayRecordWriteResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: CreateGraphSubscriptionRequest.self, context: context)
      let record: [String: Any] = [
        "$type": PublicationLexicons.graphSubscription,
        "publication": body.publication,
      ]
      guard let uri = try await repo.createRecord(
        auth: auth,
        collection: PublicationLexicons.graphSubscription,
        record: record
      ) else {
        throw HTTPError(.badGateway, message: "Subscription create did not return uri")
      }
      return GatewayRecordWriteResponse(uri: uri, rkey: rkeyFromUri(uri) ?? uri)
    }

    group.delete("/v1/publications/subscriptions/:rkey") { _, context async throws -> HTTPResponse.Status in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let rkey = context.coreContext.parameters.get("rkey") else {
        throw HTTPError(.badRequest, message: "Missing rkey")
      }
      try await repo.deleteRecord(
        auth: auth,
        collection: PublicationLexicons.graphSubscription,
        rkey: rkey
      )
      return .ok
    }

    group.post("/v1/publications/rss-subscriptions") { request, context async throws -> GatewayRecordWriteResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: CreateRssSubscriptionRequest.self, context: context)
      let now = iso8601Now()
      var record: [String: Any] = [
        "$type": PublicationLexicons.skyreaderFeedSubscription,
        "feedUrl": body.feedUrl,
        "createdAt": now,
        "updatedAt": now,
        "source": "the-social-wire",
        "sourceType": "rss",
      ]
      if let title = body.title { record["title"] = title }
      if let siteUrl = body.siteUrl { record["siteUrl"] = siteUrl }
      guard let uri = try await repo.createRecord(
        auth: auth,
        collection: PublicationLexicons.skyreaderFeedSubscription,
        record: record
      ) else {
        throw HTTPError(.badGateway, message: "RSS subscription create did not return uri")
      }
      return GatewayRecordWriteResponse(uri: uri, rkey: rkeyFromUri(uri) ?? uri)
    }

    group.delete("/v1/publications/rss-subscriptions/:rkey") { _, context async throws -> HTTPResponse.Status in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let rkey = context.coreContext.parameters.get("rkey") else {
        throw HTTPError(.badRequest, message: "Missing rkey")
      }
      try await repo.deleteRecord(
        auth: auth,
        collection: PublicationLexicons.skyreaderFeedSubscription,
        rkey: rkey
      )
      return .ok
    }

    group.post("/v1/reader/read-marks") { request, context async throws -> HTTPResponse.Status in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: ReaderReadMarkRequest.self, context: context)
      let now = iso8601Now()
      let readAt = body.readAt ?? now
      try await repo.putRecord(
        auth: auth,
        collection: PublicationLexicons.entryReadState,
        rkey: DeterministicKeys.entryReadStateRKey(subjectURI: body.subjectUri),
        record: [
          "$type": PublicationLexicons.entryReadState,
          "subjectUri": body.subjectUri,
          "readAt": readAt,
          "updatedAt": now,
        ]
      )
      return .ok
    }

    group.delete("/v1/reader/read-marks") { request, context async throws -> HTTPResponse.Status in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: ReaderReadMarkDeleteRequest.self, context: context)
      try await repo.deleteRecord(
        auth: auth,
        collection: PublicationLexicons.entryReadState,
        rkey: DeterministicKeys.entryReadStateRKey(subjectURI: body.subjectUri)
      )
      return .ok
    }

    group.post("/v1/reader/mark-all-read") { request, context async throws -> MarkAllReadResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: MarkAllReadRequest.self, context: context)
      let now = iso8601Now()
      var marked = 0
      for subjectUri in body.subjectUris {
        try await repo.putRecord(
          auth: auth,
          collection: PublicationLexicons.entryReadState,
          rkey: DeterministicKeys.entryReadStateRKey(subjectURI: subjectUri),
          record: [
            "$type": PublicationLexicons.entryReadState,
            "subjectUri": subjectUri,
            "readAt": now,
            "updatedAt": now,
          ]
        )
        marked += 1
      }
      return MarkAllReadResponse(marked: marked)
    }
  }

  private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private func rkeyFromUri(_ uri: String) -> String? {
    guard let parsed = RenderFieldExtractor.parseAtUri(uri) else { return nil }
    return parsed.rkey
  }
}

struct GatewayRecordWriteResponse: Codable, Sendable, ResponseEncodable {
  let uri: String
  let rkey: String
}

struct CreateFolderRequest: Codable, Sendable {
  let name: String
  let sortOrder: Int?
  let icon: String?
  let iconImage: String?
}

struct UpdateFolderRequest: Codable, Sendable {
  let name: String?
  let sortOrder: Int?
  let icon: String?
  let iconImage: String?
}

struct UpsertPublicationPrefsRequest: Codable, Sendable {
  let publicationId: String
  let folderId: String?
  let rkey: String?
  let existingRkey: String?
  let sortOrder: Int?
  let hidden: Bool?
  let createdAt: String?
}

struct CreateGraphSubscriptionRequest: Codable, Sendable {
  let publication: String
}

struct CreateRssSubscriptionRequest: Codable, Sendable {
  let feedUrl: String
  let title: String?
  let siteUrl: String?
}

struct ReaderReadMarkRequest: Codable, Sendable {
  let subjectUri: String
  let readAt: String?
}

struct ReaderReadMarkDeleteRequest: Codable, Sendable {
  let subjectUri: String
}

struct MarkAllReadRequest: Codable, Sendable {
  let subjectUris: [String]
}

struct MarkAllReadResponse: Codable, Sendable, ResponseEncodable {
  let marked: Int
}
