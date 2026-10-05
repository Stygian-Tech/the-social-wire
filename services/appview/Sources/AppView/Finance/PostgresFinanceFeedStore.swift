import FinanceCore
import Foundation
import Logging
import PostgresNIO
import WireCore

actor PostgresFinanceFeedStore {
  private let pool: PostgresClient
  private let logger: Logger
  private let config: FinanceDiscoveryConfig
  private let codec: FinanceCursorCodec
  private let hasher: WireActorHasher
  private let wire: any WireFeedStore
  private let selections: FinanceSelectionProjection
  private let transport: (any WireCorpusTransport)?
  private let openFIGI: OpenFIGIAdapter
  private let retention: FinanceSnapshotRetention
  private var importedCatalogGeneration: String?
  private var lastProviderSearch = Date.distantPast
  private var searchCache: [String: (Date, [FinanceInstrument])] = [:]

  init(pool: PostgresClient, logger: Logger, config: FinanceDiscoveryConfig,
    wire: any WireFeedStore, selections: FinanceSelectionProjection, transport: (any WireCorpusTransport)? = nil) throws {
    guard let secret = config.cursorSecret else { throw WireServingError.unavailable }
    self.pool = pool; self.logger = logger; self.config = config; self.wire = wire
    self.selections = selections; self.transport = transport
    codec = try FinanceCursorCodec(secret: secret)
    hasher = try WireActorHasher(secret: Data(secret.utf8))
    openFIGI = OpenFIGIAdapter(apiKey: config.openFIGIKey)
    retention = FinanceSnapshotRetention(pool: pool, logger: logger)
  }

  func availability(now: Date) async throws -> FinanceFeedAvailability {
    var hasFinance = false
    if config.catalogRightsConfirmed && config.mode == .visible {
      if let transport {
        if let reply = try? await transport.get(target: "/internal/wire/v1/finance?language=en") {
          if reply.statusCode == 200, reply.contractVersion == 3,
            let source = try? Self.decoder().decode(FinanceSourceGeneration.self, from: reply.body) {
            hasFinance = source.language == "en" && source.expiresAt > now && !source.candidates.isEmpty
            if hasFinance { try await importCatalog(source: source, now: now) }
          }
        }
      } else {
        let rows = try await pool.query("SELECT EXISTS (SELECT 1 FROM finance_generations WHERE expires_at > \(now) AND is_active = TRUE)", logger: logger)
        for try await row in rows { hasFinance = try row.decode(Bool.self) }
      }
    }
    // Initial reference-provider outages still permit exact-language, quality-gated financial news.
    if !hasFinance, config.catalogRightsConfirmed, config.mode == .visible {
      hasFinance = (try? await fallback(language: "en", now: now)) != nil
    }
    let ready = hasFinance
    return FinanceFeedAvailability(enabled: config.mode == .visible, available: ready,
      widgetsEnabled: config.widgetsEnabled, feeds: FinanceNamedFeeds.catalog(instruments: try await loadCatalog()))
  }

  func instruments(query: String, now: Date) async throws -> [FinanceInstrument] {
    guard config.mode.canServeAPI, config.catalogRightsConfirmed else { throw WireServingError.unavailable }
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty, q.count <= 200 else { throw WireServingError.invalidCursor }
    let normalized = q.lowercased()
    if q.hasPrefix("fin_") {
      // Resolve existing public interests locally; opaque references never leave for a provider.
      let rows = try await pool.query("SELECT payload::text FROM finance_instruments WHERE instrument_id = \(q)", logger: logger)
      for try await row in rows {
        return config.providerPolicy.filter([FinanceReviewedInstrumentMetadata.apply(to: try JSONDecoder().decode(FinanceInstrument.self,
          from: Data(try row.decode(String.self).utf8)))])
      }
      return []
    }
    if let cached = searchCache[normalized], now.timeIntervalSince(cached.0) < 600 { return cached.1 }
    let catalog = try await loadCatalog()
    var found = catalog.filter { $0.isActive && ($0.id == q || $0.name.localizedCaseInsensitiveContains(q)
      || $0.symbol.localizedCaseInsensitiveContains(q) || $0.aliases.contains(where: { $0.localizedCaseInsensitiveContains(q) })) }
    if !q.hasPrefix("fin_"), found.count < 5, now.timeIntervalSince(lastProviderSearch) >= (config.openFIGIKey == nil ? 60 : 12),
      try await claimProviderSearch(now: now) {
      lastProviderSearch = now
      do {
        let remote = Array(try await openFIGI.search(query: q).prefix(50)).map { FinanceReviewedInstrumentMetadata.apply(to: $0) }
        let encoder = JSONEncoder()
        for instrument in remote {
          let payload = String(decoding: try encoder.encode(instrument), as: UTF8.self)
          let key = instrument.providerID
          try await pool.query("""
            INSERT INTO finance_instruments (instrument_id, provider_key, payload, updated_at)
            VALUES (\(instrument.id), \(key), \(payload)::jsonb, \(now))
            ON CONFLICT (provider_key) DO UPDATE SET updated_at=EXCLUDED.updated_at,
              payload=EXCLUDED.payload || jsonb_build_object('aliases', finance_instruments.payload->'aliases',
                'sectorIDs', finance_instruments.payload->'sectorIDs', 'tradingViewSymbol',
                CASE WHEN finance_instruments.payload->>'symbol' = EXCLUDED.payload->>'symbol'
                  THEN finance_instruments.payload->'tradingViewSymbol' ELSE 'null'::jsonb END)
            """, logger: logger)
        }
        found.append(contentsOf: remote)
      } catch {
        // Provider failure never removes catalog entries or blocks the article feed.
        logger.warning("Finance reference search unavailable")
      }
    }
    var seen = Set<String>()
    found = Array(found.filter { seen.insert($0.id).inserted }.sorted {
      let lhsExact = $0.symbol.caseInsensitiveCompare(q) == .orderedSame
      let rhsExact = $1.symbol.caseInsensitiveCompare(q) == .orderedSame
      if lhsExact != rhsExact { return lhsExact }
      return ($0.name, $0.exchange ?? "", $0.id) < ($1.name, $1.exchange ?? "", $1.id)
    }.prefix(50))
    if searchCache.count >= 100 { searchCache.removeAll() }
    searchCache[normalized] = (now, found)
    return found
  }

  private func claimProviderSearch(now: Date) async throws -> Bool {
    let interval = config.openFIGIKey == nil ? 60.0 : 12.0
    let rows = try await pool.query("""
      INSERT INTO finance_provider_request_budget (provider_key, requested_at) VALUES ('openfigi-search', \(now))
      ON CONFLICT (provider_key) DO UPDATE SET requested_at=EXCLUDED.requested_at
      WHERE finance_provider_request_budget.requested_at <= \(now.addingTimeInterval(-interval))
      RETURNING provider_key
      """, logger: logger)
    for try await _ in rows { return true }
    return false
  }

  func page(cursor: String?, limit: Int, language: String?, viewerDID: String?, refresh: Bool, now: Date, feed: String = "finance", hideCrypto: Bool = false) async throws -> FinancePage {
    guard config.mode.canServeAPI, config.catalogRightsConfirmed else { throw WireServingError.unavailable }
    let lang = Self.language(language)
    guard feed.utf8.count <= 256 else { throw WireServingError.invalidCursor }
    let initialSource = cursor == nil ? try await source(language: lang, now: now) : nil
    let initialCatalog = try await loadCatalog()
    // Named definitions are resolved again after source import, which may hydrate a cold catalog.
    let preference = try await selections.selections(viewerDID: viewerDID, refresh: refresh && cursor == nil, now: now)
    let baseRevision = feed == "finance" ? FinanceIdentity.preferenceFingerprint(instrumentIDs: preference.instruments, sectorIDs: preference.sectors)
      + ":" + config.providerPolicy.revision
      : FinanceNamedFeeds.revision(instruments: initialCatalog) + ":" + config.providerPolicy.revision
    let revision = baseRevision + (hideCrypto ? ":hide-crypto-v1" : ":show-crypto-v1")
    let snapshotScope = feed == "finance" ? try hasher.hash(viewerDID ?? "anonymous-finance") : "shared:" + feed
    let scope = try hasher.hash(viewerDID ?? "anonymous-finance")
    let snapshot: FinanceSourceGeneration
    let start: Int
    if let cursor {
      let decoded: FinanceCursor
      do { decoded = try codec.decode(cursor, language: lang, preferenceFingerprint: revision, viewerScope: scope, now: now, feed: feed) }
      catch FinanceCursorError.expired { throw WireServingError.cursorExpired }
      catch { throw WireServingError.invalidCursor }
      guard let id = UUID(uuidString: decoded.generationID),
        let retained = try await retainedSnapshot(id: id, scope: snapshotScope, language: lang, revision: revision, now: now)
      else { throw WireServingError.cursorExpired }
      snapshot = retained; start = decoded.nextOrdinal
    } else {
      guard let source = initialSource else { throw WireServingError.unavailable }
      guard source.expiresAt > now else { throw WireServingError.unavailable }
      let id = UUID()
      let catalog = try await loadCatalog()
      guard let definition = FinanceNamedFeeds.catalog(instruments: catalog).first(where: { $0.id == feed }) else { throw WireServingError.invalidCursor }
      let permittedIDs = Set(catalog.map(\.id))
      let ranked: [FinanceRankCandidate]
      if feed == "finance" {
        ranked = FinanceRanker.rank(candidates: source.candidates.filter { !hideCrypto || !FinanceAssetKind.isCryptoStory(title: $0.item.title, summary: $0.item.summary, analysis: $0.analysis, catalog: catalog) },
          instrumentIDs: Set(preference.instruments).intersection(permittedIDs), sectorIDs: Set(preference.sectors))
      } else {
        let matching = source.candidates.compactMap { candidate -> FinanceRankCandidate? in
          let analysis = FinanceResolver.analyze(title: candidate.item.title, summary: candidate.item.summary,
              structuredInstrumentIDs: candidate.analysis.associations.filter { $0.evidence.contains("structured-metadata") && $0.confidence.isFinite && (0.9...1).contains($0.confidence) && $0.resolverVersion == FinanceResolver.version }.map(\.instrumentID),
              verifiedInstrumentIDs: FinanceReviewedInstrumentMetadata.verifiedInstrumentIDs(domain: candidate.item.source.domain, account: nil), catalog: catalog)
          guard definition.matches(analysis, title: candidate.item.title, summary: candidate.item.summary),
            !hideCrypto || !FinanceAssetKind.isCryptoStory(title: candidate.item.title, summary: candidate.item.summary, analysis: analysis, catalog: catalog) else { return nil }
          return FinanceRankCandidate(item: candidate.item, analysis: analysis, baseScore: candidate.baseScore, majorGlobal: candidate.majorGlobal)
        }
        ranked = FinanceRanker.rank(candidates: matching, reserveGlobal: false)
      }
      let proposed = FinanceSourceGeneration(generationId: id.uuidString.lowercased(), generatedAt: source.generatedAt,
        expiresAt: min(source.expiresAt, now.addingTimeInterval(48 * 60 * 60)), language: lang, candidates: ranked, source: source.source)
      snapshot = try await persistSnapshot(proposed, sourceID: source.generationId, scope: snapshotScope, revision: revision, sourceSnapshot: source)
      start = 0
    }
    guard start <= snapshot.candidates.count else { throw WireServingError.invalidCursor }
    let catalog = try await loadCatalog()
    guard let definition = FinanceNamedFeeds.catalog(instruments: catalog).first(where: { $0.id == feed }) else { throw WireServingError.invalidCursor }
    let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var accepted: [FinanceFeedItem] = []; var ordinal = start
    // getItem rechecks current labels, deletion and viewer state; cached snapshots are never approval.
    while ordinal < snapshot.candidates.count, accepted.count < limit {
      let batchEnd = min(ordinal + 10, snapshot.candidates.count)
      let batch = Array(snapshot.candidates[ordinal..<batchEnd])
      let current = try await withThrowingTaskGroup(of: (String, WireFeedItem?).self) { group in
        for candidate in batch {
          group.addTask { [wire] in
            (candidate.item.itemID, try await wire.getItem(itemId: candidate.item.itemID, viewerDid: viewerDID)?.item)
          }
        }
        var result: [String: WireFeedItem] = [:]
        for try await (id, item) in group { if let item { result[id] = item } }
        return result
      }
      for candidate in batch {
        ordinal += 1
        guard let item = current[candidate.item.itemID] else { continue }
        let analysis = feed == "finance" && item.title == candidate.item.title && item.summary == candidate.item.summary
          && item.source.domain == candidate.item.source.domain
          && candidate.analysis.resolverVersion == FinanceResolver.version
          ? candidate.analysis : FinanceResolver.analyze(title: item.title, summary: item.summary,
          structuredInstrumentIDs: item.title == candidate.item.title && item.summary == candidate.item.summary && item.source.domain == candidate.item.source.domain
            ? candidate.analysis.associations.filter { $0.evidence.contains("structured-metadata") && $0.confidence.isFinite && (0.9...1).contains($0.confidence) && $0.resolverVersion == FinanceResolver.version }.map(\.instrumentID) : [],
          verifiedInstrumentIDs: FinanceReviewedInstrumentMetadata.verifiedInstrumentIDs(domain: item.source.domain, account: nil), catalog: catalog)
        guard analysis.eligible, definition.matches(analysis, title: item.title, summary: item.summary),
          !hideCrypto || !FinanceAssetKind.isCryptoStory(title: item.title, summary: item.summary, analysis: analysis, catalog: catalog) else { continue }
        let matches = analysis.associations.compactMap { match -> FinanceMatchedInstrument? in
          guard match.confidence.isFinite, (0.9...1).contains(match.confidence), let instrument = byID[match.instrumentID] else { return nil }
          return FinanceMatchedInstrument(instrument: instrument, confidence: match.confidence, prominence: match.prominence, evidence: match.evidence, resolverVersion: match.resolverVersion)
        }
        accepted.append(FinanceFeedItem(story: item, instruments: matches,
          sectorIDs: analysis.sectorIDs, materiality: analysis.materiality, majorGlobal: candidate.majorGlobal, macroTopics: analysis.macroTopics ?? []))
        if accepted.count == limit { break }
      }
    }
    let next = ordinal < snapshot.candidates.count ? try codec.encode(FinanceCursor(feed: feed, generationID: snapshot.generationId,
      language: lang, preferenceFingerprint: revision, viewerScope: scope, nextOrdinal: ordinal, expiresAt: snapshot.expiresAt)) : nil
    let stale = now.timeIntervalSince(snapshot.generatedAt) > 600
    return FinancePage(generationId: snapshot.generationId, generatedAt: snapshot.generatedAt,
      expiresAt: snapshot.expiresAt, language: lang, preferenceRevision: revision, cursor: next,
      source: snapshot.source == .simplifiedFallback ? .simplifiedFallback : stale ? .staleGeneration : .ranked, degraded: stale || snapshot.source == .simplifiedFallback, items: accepted, widgetsEnabled: config.widgetsEnabled, feedId: feed)
  }

  private func loadCatalog() async throws -> [FinanceInstrument] {
    let rows = try await pool.query("SELECT payload::text FROM finance_instruments ORDER BY instrument_id LIMIT 50000", logger: logger)
    var result: [FinanceInstrument] = []
    for try await row in rows { result.append(FinanceReviewedInstrumentMetadata.apply(to: try JSONDecoder().decode(FinanceInstrument.self, from: Data(try row.decode(String.self).utf8)))) }
    return config.providerPolicy.filter(result)
  }

  private func source(language: String, now: Date) async throws -> FinanceSourceGeneration {
    if let transport {
      let reply = try await transport.get(target: "/internal/wire/v1/finance?language=\(language)")
      guard reply.statusCode == 200, reply.contractVersion == 3 else { return try await fallback(language: language, now: now) }
      let source = try Self.decoder().decode(FinanceSourceGeneration.self, from: reply.body)
      guard source.language == language, source.expiresAt > now, source.candidates.count <= 5000 else { throw WireServingError.unavailable }
      try await importCatalog(source: source, now: now)
      return source
    }
    let rows = try await pool.query("""
      SELECT generation_id, generated_at, expires_at, payload::text, serving_source FROM finance_generations
      WHERE language = \(language) AND expires_at > \(now) ORDER BY is_active DESC, generated_at DESC LIMIT 1
      """, logger: logger)
    for try await row in rows {
      let (id, created, expiry, payload, source) = try row.decode((UUID, Date, Date, String, String).self)
      return FinanceSourceGeneration(generationId: id.uuidString.lowercased(), generatedAt: created,
        expiresAt: expiry, language: language, candidates: try Self.decoder().decode([FinanceRankCandidate].self, from: Data(payload.utf8)), source: WirePageSource(rawValue: source))
    }
    return try await fallback(language: language, now: now)
  }

  private func importCatalog(source: FinanceSourceGeneration, now: Date) async throws {
    let revision = source.generationId + ":" + config.providerPolicy.revision
    guard importedCatalogGeneration != revision else { return }
    let instruments = config.providerPolicy.filter(source.instruments)
    guard instruments.count <= 5000 else { throw WireServingError.unavailable }
    let payload = String(decoding: try Self.encoder().encode(instruments), as: UTF8.self)
    // One atomic statement per source revision, instead of a write round trip per instrument per reader.
    try await pool.query("""
      INSERT INTO finance_instruments (instrument_id, provider_key, payload, updated_at)
      SELECT instrument->>'id', 'corpus:' || (instrument->>'id'), instrument, \(now)
      FROM jsonb_array_elements(\(payload)::jsonb) instrument
      ON CONFLICT (instrument_id) DO UPDATE SET payload=EXCLUDED.payload, updated_at=EXCLUDED.updated_at
      WHERE finance_instruments.payload IS DISTINCT FROM EXCLUDED.payload
      """, logger: logger)
    importedCatalogGeneration = revision
  }

  private func fallback(language: String, now: Date) async throws -> FinanceSourceGeneration {
    let catalog = try await loadCatalog()
    let page = try await wire.getFeed(cursor: nil, limit: 50, language: language, viewerDid: nil, now: now)
    guard page.language == language else { throw WireServingError.unavailable }
    let candidates = page.items.enumerated().compactMap { ordinal, item -> FinanceRankCandidate? in
      let analysis = FinanceResolver.analyze(title: item.title, summary: item.summary,
          verifiedInstrumentIDs: FinanceReviewedInstrumentMetadata.verifiedInstrumentIDs(domain: item.source.domain, account: nil), catalog: catalog)
      guard analysis.eligible else { return nil }
      return FinanceRankCandidate(item: item, analysis: analysis, baseScore: Double(50 - ordinal),
        majorGlobal: analysis.associations.isEmpty && analysis.materiality != "price-chatter")
    }
    guard !candidates.isEmpty else { throw WireServingError.unavailable }
    return FinanceSourceGeneration(generationId: UUID().uuidString.lowercased(), generatedAt: now,
      expiresAt: now.addingTimeInterval(48 * 60 * 60), language: language, candidates: candidates, source: .simplifiedFallback)
  }

  private func persistSnapshot(_ snapshot: FinanceSourceGeneration, sourceID: String, scope: String, revision: String, sourceSnapshot: FinanceSourceGeneration) async throws -> FinanceSourceGeneration {
    guard let sourceUUID = UUID(uuidString: sourceID), let id = UUID(uuidString: snapshot.generationId) else { throw WireServingError.unavailable }
    let payload = try Self.encoder().encode(snapshot.candidates)
    // Development imports only the HMAC-authorized public candidate snapshot, never raw network state.
    if transport != nil || snapshot.source == .simplifiedFallback {
      _ = await retention.purgeIfDue(now: Date())
      let sourcePayload = String(decoding: try Self.encoder().encode(sourceSnapshot.candidates), as: UTF8.self)
      try await pool.query("""
        INSERT INTO finance_generations (generation_id, source_generation_id, language, algorithm_version, generated_at, expires_at, payload, serving_source)
        VALUES (\(sourceUUID), \(sourceUUID), \(snapshot.language), 'finance-v1', \(snapshot.generatedAt), \(snapshot.expiresAt), \(sourcePayload)::jsonb, \(snapshot.source?.rawValue ?? "ranked"))
        ON CONFLICT (generation_id) DO NOTHING
        """, logger: logger)
    }
    let rows = try await pool.query("""
      INSERT INTO finance_personalized_snapshots (snapshot_id, source_generation_id, viewer_scope, language, preference_revision, generated_at, expires_at, payload, serving_source)
      VALUES (\(id), \(sourceUUID), \(scope), \(snapshot.language), \(revision), \(snapshot.generatedAt), \(snapshot.expiresAt), \(String(decoding: payload, as: UTF8.self))::jsonb, \(snapshot.source?.rawValue ?? "ranked"))
      ON CONFLICT (source_generation_id, viewer_scope, language, preference_revision) DO UPDATE SET viewer_scope = EXCLUDED.viewer_scope
      RETURNING snapshot_id, generated_at, expires_at, payload::text, serving_source
      """, logger: logger)
    for try await row in rows {
      let (existing, generated, expires, json, source) = try row.decode((UUID, Date, Date, String, String).self)
      return FinanceSourceGeneration(generationId: existing.uuidString.lowercased(), generatedAt: generated, expiresAt: expires,
        language: snapshot.language, candidates: try Self.decoder().decode([FinanceRankCandidate].self, from: Data(json.utf8)), source: WirePageSource(rawValue: source))
    }
    throw WireServingError.unavailable
  }

  private func retainedSnapshot(id: UUID, scope: String, language: String, revision: String, now: Date) async throws -> FinanceSourceGeneration? {
    let rows = try await pool.query("""
      SELECT generated_at, expires_at, payload::text, serving_source FROM finance_personalized_snapshots
      WHERE snapshot_id = \(id) AND viewer_scope = \(scope) AND language = \(language)
        AND preference_revision = \(revision) AND expires_at > \(now)
      """, logger: logger)
    for try await row in rows {
      let (generated, expiry, payload, source) = try row.decode((Date, Date, String, String).self)
      return FinanceSourceGeneration(generationId: id.uuidString.lowercased(), generatedAt: generated, expiresAt: expiry, language: language,
        candidates: try Self.decoder().decode([FinanceRankCandidate].self, from: Data(payload.utf8)), source: WirePageSource(rawValue: source))
    }
    return nil
  }
  private static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
  private static func decoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
  static func language(_ raw: String?) -> String {
    let primary = (raw ?? "und").lowercased().split(separator: "-").first.map(String.init) ?? "und"
    return primary.count >= 2 && primary.count <= 8 && primary.allSatisfy({ $0.isASCII && $0.isLetter }) ? primary : "und"
  }
}
