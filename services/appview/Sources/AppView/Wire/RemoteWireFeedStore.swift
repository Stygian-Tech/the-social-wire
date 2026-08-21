import Foundation
import WireCore

actor RemoteWireFeedStore: WireFeedStore {
  private let transport: any WireCorpusTransport
  private let cursorCodec: WireCursorCodec
  private let mode: WireDiscoveryMode
  private let moderationCache: WireViewerModerationCache

  init(
    transport: any WireCorpusTransport,
    cursorSecret: String,
    mode: WireDiscoveryMode,
    moderationCache: WireViewerModerationCache
  ) throws {
    self.transport = transport
    self.cursorCodec = try WireCursorCodec(secret: cursorSecret)
    self.mode = mode
    self.moderationCache = moderationCache
  }

  func getFeed(
    cursor: String?,
    limit: Int,
    language: String?,
    viewerDid: String?,
    now: Date
  ) async throws -> WirePage {
    guard mode.servesAPI else { throw WireServingError.unavailable }
    let safeLimit = max(1, min(limit, 50))
    let requestedLanguage = Self.primaryLanguage(language)
    var generationID: String?
    var scanOrdinal = 0
    if let cursor {
      let decoded: WireCursor
      do {
        decoded = try cursorCodec.decode(cursor)
      } catch {
        throw WireServingError.invalidCursor
      }
      guard decoded.language == requestedLanguage || decoded.language == "und",
        UUID(uuidString: decoded.generationID) != nil
      else {
        throw WireServingError.invalidCursor
      }
      generationID = decoded.generationID
      scanOrdinal = decoded.nextOrdinal
    }

    let moderation = try await moderationSnapshot(viewerDID: viewerDid, now: now)
    var accepted: [WireCorpusRow] = []
    var lastPage: WireCorpusPage?
    var exhausted = false
    var scanned = 0
    while accepted.count <= safeLimit, !exhausted, scanned < 5_000 {
      let target = Self.feedTarget(
        language: requestedLanguage,
        generationID: generationID,
        startOrdinal: scanOrdinal,
        limit: 500
      )
      let page: WireCorpusPage = try await fetch(target: target)
      if let pinned = generationID, page.generationID != pinned {
        throw WireServingError.cursorExpired
      }
      if let previous = lastPage,
        previous.generationID != page.generationID || previous.language != page.language
      {
        throw WireServingError.unavailable
      }
      generationID = page.generationID
      lastPage = page
      scanned += page.rows.count
      if let last = page.rows.last { scanOrdinal = last.ordinal + 1 }
      accepted.append(contentsOf: page.rows.filter { row in
        moderation?.allows(
          item: row.sourceActorKey ?? row.item.itemID,
          title: row.item.title,
          summary: row.item.summary,
          representativeURI: row.item.representativeURI
        ) ?? true
      })
      exhausted = page.exhausted || page.source == .simplifiedFallback || page.rows.isEmpty
    }
    guard let page = lastPage else { throw WireServingError.unavailable }
    let pageRows = Array(accepted.prefix(safeLimit))
    let nextCursor: String?
    if page.source == .simplifiedFallback {
      nextCursor = nil
    } else if accepted.count > safeLimit, let last = pageRows.last {
      nextCursor = try cursorCodec.encode(
        WireCursor(
          generationID: page.generationID,
          language: page.language,
          nextOrdinal: last.ordinal + 1
        )
      )
    } else if !exhausted {
      nextCursor = try cursorCodec.encode(
        WireCursor(
          generationID: page.generationID,
          language: page.language,
          nextOrdinal: scanOrdinal
        )
      )
    } else {
      nextCursor = nil
    }
    return WirePage(
      generationID: page.generationID,
      generatedAt: page.generatedAt,
      language: page.language,
      cursor: nextCursor,
      source: page.source,
      degraded: page.degraded,
      items: pageRows.map(\.item)
    )
  }

  func getItem(itemId: String, viewerDid: String?) async throws -> WireItemDetail? {
    guard mode.servesAPI else { throw WireServingError.unavailable }
    let target = Self.target(path: "/internal/wire/v1/item", query: [("itemId", itemId)])
    let response = try await transportResponse(target: target, allowsNotFound: true)
    guard response.statusCode != 404 else { return nil }
    let corpusItem: WireCorpusItem = try decode(response.body)
    let moderation = try await moderationSnapshot(viewerDID: viewerDid, now: Date())
    guard moderation?.allows(
      item: corpusItem.sourceActorKey ?? corpusItem.item.itemID,
      title: corpusItem.item.title,
      summary: corpusItem.item.summary,
      representativeURI: corpusItem.item.representativeURI
    ) ?? true else { return nil }
    return WireItemDetail(item: corpusItem.item, embedURL: corpusItem.item.canonicalURL)
  }

  func getCatalog(now: Date) async throws -> WireFeedCatalog {
    guard mode.servesAPI else {
      return WireFeedCatalog(enabled: false, available: false, supportedLanguages: [])
    }
    let snapshot: WireCorpusCatalog = try await fetch(target: "/internal/wire/v1/catalog")
    return WireFeedCatalog(
      enabled: true,
      available: mode.isVisible && snapshot.available,
      supportedLanguages: snapshot.supportedLanguages,
      latestGenerationID: snapshot.latestGenerationID,
      generatedAt: snapshot.generatedAt
    )
  }

  private func fetch<Value: Decodable>(target: String) async throws -> Value {
    let response = try await transportResponse(target: target, allowsNotFound: false)
    return try decode(response.body)
  }

  private func transportResponse(
    target: String,
    allowsNotFound: Bool
  ) async throws -> WireCorpusTransportResponse {
    let response: WireCorpusTransportResponse
    do {
      response = try await transport.get(target: target)
    } catch {
      throw WireServingError.unavailable
    }
    switch response.statusCode {
    case 200:
      guard response.contractVersion == 1 else { throw WireServingError.unavailable }
      return response
    case 400: throw WireServingError.invalidCursor
    case 404 where allowsNotFound: return response
    case 410: throw WireServingError.cursorExpired
    case 503: throw WireServingError.moderationUnavailable
    default: throw WireServingError.unavailable
    }
  }

  private func decode<Value: Decodable>(_ data: Data) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do { return try decoder.decode(Value.self, from: data) }
    catch { throw WireServingError.unavailable }
  }

  private func moderationSnapshot(
    viewerDID: String?,
    now: Date
  ) async throws -> WireViewerModerationSnapshot? {
    guard let viewerDID else { return nil }
    guard let snapshot = await moderationCache.usable(viewerDID: viewerDID, now: now) else {
      throw WireServingError.moderationUnavailable
    }
    return snapshot
  }

  private static func feedTarget(
    language: String,
    generationID: String?,
    startOrdinal: Int,
    limit: Int
  ) -> String {
    var query: [(String, String)] = [
      ("language", language),
      ("limit", String(limit)),
      ("startOrdinal", String(startOrdinal)),
    ]
    if let generationID { query.append(("generationId", generationID)) }
    return target(path: "/internal/wire/v1/feed", query: query)
  }

  private static func target(path: String, query: [(String, String)]) -> String {
    var components = URLComponents()
    components.queryItems = query.sorted { left, right in left.0 < right.0 }
      .map { URLQueryItem(name: $0.0, value: $0.1) }
    guard let encoded = components.percentEncodedQuery, !encoded.isEmpty else { return path }
    return "\(path)?\(encoded)"
  }

  private static func primaryLanguage(_ raw: String?) -> String {
    guard let raw else { return "und" }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let primary = normalized.split(separator: "-").first,
      primary.count >= 2, primary.count <= 8,
      primary.allSatisfy({ $0.isASCII && $0.isLetter })
    else { return "und" }
    return String(primary)
  }
}
