import CryptoKit
import Foundation
import Observation
import ReadStateCore

@MainActor @Observable
final class PDSReadStateSyncService {
    static let publicHistoryNotice = "Your read and unread history will be public on your PDS. This includes your existing history and future changes."
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOCIALWIRE_PDS_READ_STATE_ENABLED"] == "true"
            || Bundle.main.object(forInfoDictionaryKey: "PDSReadStateEnabled") as? Bool == true
    }
    var onSynchronized: ((String) async -> Void)?
    var onPendingChanged: ((String) -> Void)?
    private let xrpc: XRPCClient
    private let gateway: SocialWireGatewayClient
    private let currentViewer: () async throws -> String?
    private let statusProvider: (String) async throws -> PDSReadStateStatus
    private let engineProvider: ((String) throws -> ReadStateSyncEngine)?
    private let defaults: UserDefaults
    private var viewerDid: String?
    private var epoch = UUID()
    private var engine: ReadStateSyncEngine?
    private var wakeup: Task<Void, Never>?
    private(set) var pendingCount = 0
    private(set) var projectionReady = true
    static let restoringMessage = ReadStateSyncFailure.projectionNotReady.localizedDescription
    static let scopeConflictMessage = ReadStateSyncFailure.migrationScopeConflict.localizedDescription
    private(set) var statusMessage: String?
    private(set) var authority: PDSReadStateStatus.Authority?
    private(set) var isMigrating = false
    private(set) var requiresReauthentication = false
    private(set) var pendingExactOverrides: [String: ReadStateOperation.State] = [:]
    private var knownPDSViewers: Set<String> {
        get { Set(defaults.stringArray(forKey: "the-social-wire.pds-read-state-viewers.v1") ?? []) }
        set { defaults.set(Array(newValue), forKey: "the-social-wire.pds-read-state-viewers.v1") }
    }
    var isPDSAuthoritative: Bool { authority == .pds || viewerDid.map(knownPDSViewers.contains) == true }

    init(xrpc: XRPCClient, gateway: SocialWireGatewayClient, defaults: UserDefaults = .standard,
         currentViewer: (() async throws -> String?)? = nil,
         statusProvider: ((String) async throws -> PDSReadStateStatus)? = nil,
         engineProvider: ((String) throws -> ReadStateSyncEngine)? = nil) {
        self.xrpc = xrpc; self.gateway = gateway; self.defaults = defaults
        self.currentViewer = currentViewer ?? { try await xrpc.currentDID() }
        self.statusProvider = statusProvider ?? { viewer in
            try await gateway.pdsReadStateRequest("getReadStateStatus", expectedViewer: viewer)
        }
        self.engineProvider = engineProvider
    }

    func reset() {
        epoch = UUID()
        wakeup?.cancel(); wakeup = nil
        engine = nil; viewerDid = nil; pendingCount = 0; statusMessage = nil
        authority = nil; projectionReady = true; isMigrating = false; requiresReauthentication = false
        pendingExactOverrides = [:]
    }

    private func bind(_ viewer: String) {
        if viewerDid != viewer { reset(); viewerDid = viewer }
    }

    private func check(_ viewer: String, epoch expected: UUID) async throws {
        try Task.checkCancellation()
        guard viewerDid == viewer, epoch == expected else { throw ReadStateSyncFailure.accountChanged }
        let current = try await currentViewer()
        guard current == viewer, viewerDid == viewer, epoch == expected else { throw ReadStateSyncFailure.accountChanged }
    }

    /// Ordinary reads and actions only discover authority; publishing is explicit.
    func ensureAuthority(viewer: String) async throws -> Bool {
        bind(viewer)
        let expected = epoch
        try await check(viewer, epoch: expected)
        if authority == nil { try await refreshStatus(viewer: viewer) }
        try await check(viewer, epoch: expected)
        if isPDSAuthoritative {
            let engine = try engineForViewer(viewer)
            try await engine.discardVerifiedMigration()
            try await updatePending(engine, viewer: viewer, epoch: expected)
            return true
        }
        return false
    }

    func refreshStatus(viewer: String) async throws {
        bind(viewer)
        let expected = epoch
        do {
            let status = try await checkedStatus(viewer, epoch: expected)
            authority = status.authority
            projectionReady = status.projectionReady
            if !projectionReady { statusMessage = Self.restoringMessage }
            else if statusMessage == Self.restoringMessage { statusMessage = nil }
            if status.authority == .pds {
                knownPDSViewers.insert(viewer)
                let engine = try engineForViewer(viewer)
                try await engine.discardVerifiedMigration()
                try await updatePending(engine, viewer: viewer, epoch: expected)
            }
        } catch SocialWireError.appViewUnavailable {
            try await check(viewer, epoch: expected)
            guard !isPDSAuthoritative else { throw SocialWireError.appViewUnavailable }
            authority = .appview
        } catch {
            guard epoch == expected else { throw ReadStateSyncFailure.accountChanged }
            show(error)
            if !isPDSAuthoritative { throw error }
            // Known PDS users can queue offline; failures never restore legacy authority.
        }
    }

    func publishReadHistory(viewer: String) async throws {
        bind(viewer)
        guard !isMigrating else { return }
        let expected = epoch
        isMigrating = true
        defer { if epoch == expected { isMigrating = false } }
        do {
            try await migrate(viewer: viewer, epoch: expected)
            try await check(viewer, epoch: expected)
            authority = .pds; knownPDSViewers.insert(viewer)
            requiresReauthentication = false; statusMessage = projectionReady ? nil : Self.restoringMessage
            if let engine { try await updatePending(engine, viewer: viewer, epoch: expected) }
            await onSynchronized?(viewer)
        } catch {
            guard epoch == expected else { throw ReadStateSyncFailure.accountChanged }
            show(error); throw error
        }
    }

    func setExact(viewer: String, subjectUris: [String], state: ReadStateOperation.State, actedAt: String) async throws {
        let selection = PDSReadStateSelection(actedAt: actedAt, selection: .exact, boundaries: nil,
            subjectUris: subjectUris, calendar: nil, legacyRevision: 0, manifestCid: nil)
        try await enqueue(viewer: viewer, operations: selection.operations(state: state))
    }

    func setScope(viewer: String, scope: GatewayMarkAllReadScopeDTO, before: String? = nil,
                  previewSubjectUris: [String] = []) async throws -> PDSReadStateSelection {
        let expected = epoch
        try await check(viewer, epoch: expected)
        struct Request: Encodable {
            let scope: GatewayMarkAllReadScopeDTO
            let before: String?
            let timeZone: String
            let referenceDate: String
            let previewSubjectUris: [String]
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let body = try JSONEncoder().encode(Request(scope: scope, before: before,
            timeZone: TimeZone.current.identifier, referenceDate: formatter.string(from: Date()),
            previewSubjectUris: Array(Set(previewSubjectUris).sorted().prefix(1000))))
        let selection: PDSReadStateSelection = try await gateway.pdsReadStateRequest("prepareReadState", body: body, expectedViewer: viewer)
        try await check(viewer, epoch: expected)
        var localOverlay: [ReadStateOperation]?
        if let ids = selection.previewSubjectUris, selection.selection == .boundaries {
            localOverlay = try PDSReadStateSelection(actedAt: selection.actedAt, selection: .exact,
                boundaries: nil, subjectUris: ids, calendar: nil, legacyRevision: 0, manifestCid: nil).operations(state: .read)
        }
        try await enqueue(viewer: viewer, operations: selection.operations(state: .read), localOverlay: localOverlay)
        return selection
    }

    func flush() async {
        guard let engine, let viewer = viewerDid, isPDSAuthoritative else { return }
        let expected = epoch
        let previousCount = await engine.pendingCount
        do {
            try await check(viewer, epoch: expected)
            try await engine.flush()
            try await updatePending(engine, viewer: viewer, epoch: expected)
            requiresReauthentication = false; statusMessage = projectionReady ? nil : Self.restoringMessage
        } catch {
            guard epoch == expected else { return }
            show(error)
            try? await updatePending(engine, viewer: viewer, epoch: expected)
        }
        guard epoch == expected, viewerDid == viewer else { return }
        if previousCount > 0 && pendingCount == 0 { await onSynchronized?(viewer) }
        guard epoch == expected, viewerDid == viewer, pendingCount > 0 else { return }
        if !requiresReauthentication { statusMessage = projectionReady ? "\(pendingCount) Read History Changes Waiting to Sync" : Self.restoringMessage }
        guard !requiresReauthentication else { return }
        let deadline = await engine.retryAfter ?? Date().addingTimeInterval(2)
        guard epoch == expected else { return }
        wakeup?.cancel()
        wakeup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, self?.epoch == expected else { return }
            await self?.flush()
        }
    }

    private func enqueue(viewer: String, operations: [ReadStateOperation], localOverlay: [ReadStateOperation]? = nil) async throws {
        let expected = epoch
        try await check(viewer, epoch: expected)
        guard isPDSAuthoritative, let engine else { throw ReadStateSyncFailure.conflict }
        try await engine.enqueue(operations, localOverlay: localOverlay)
        try await updatePending(engine, viewer: viewer, epoch: expected)
        statusMessage = projectionReady ? (pendingCount == 0 ? nil : "\(pendingCount) Read History Changes Waiting to Sync") : Self.restoringMessage
        // Return after durable enqueue; the caller can update its UI before network work.
        Task { [weak self] in
            await Task.yield()
            guard self?.epoch == expected else { return }
            await self?.flush()
        }
    }

    private func updatePending(_ engine: ReadStateSyncEngine, viewer: String, epoch expected: UUID) async throws {
        let count = await engine.pendingCount
        let operations = await engine.pendingLocalOperations
        try await check(viewer, epoch: expected)
        pendingCount = count
        var overrides: [String: ReadStateOperation.State] = [:]
        for operation in operations { for uri in operation.subjectUris ?? [] { overrides[uri] = operation.state } }
        pendingExactOverrides = overrides
        onPendingChanged?(viewer)
    }

    private func show(_ error: Error) {
        if case ReadStateSyncFailure.reauthorizationRequired = error {
            requiresReauthentication = true
            statusMessage = "Sign In Again to Sync Public Read History. Pending Changes Remain on This Device."
        } else if case ReadStateSyncFailure.migrationScopeConflict = error {
            statusMessage = Self.scopeConflictMessage
        } else if case ReadStateSyncFailure.projectionNotReady = error {
            projectionReady = false
            statusMessage = Self.restoringMessage
        } else { statusMessage = "Read History Sync Pending. \(error.localizedDescription)" }
    }

    private func checkedStatus(_ viewer: String, epoch expected: UUID) async throws -> PDSReadStateStatus {
        try await check(viewer, epoch: expected)
        let status = try await statusProvider(viewer)
        try await check(viewer, epoch: expected)
        return status
    }

    private func migrate(viewer: String, epoch expected: UUID) async throws {
        let status = try await checkedStatus(viewer, epoch: expected)
        let engine = try engineForViewer(viewer)
        if status.authority == .pds { try await engine.discardVerifiedMigration(); return }
        try await xrpc.requireReadStateWriteScopes(viewerDid: viewer)
        try await check(viewer, epoch: expected)
        var rows: [ReadStateLegacyRow] = []
        var cursor: String?
        var seen = Set<String>()
        var revision: Int64?
        repeat {
            try await check(viewer, epoch: expected)
            let request = ReadStateExportInput(cursor: cursor, expectedLegacyRevision: revision, limit: 500)
            let page: PDSReadStateExportPage = try await gateway.pdsReadStateRequest("exportReadState", body: JSONEncoder().encode(request), expectedViewer: viewer)
            try await check(viewer, epoch: expected)
            guard revision == nil || revision == page.legacyRevision else { throw ReadStateSyncFailure.conflict }
            revision = page.legacyRevision
            rows.append(contentsOf: page.rows)
            guard rows.count <= 100_000 else { throw ReadStateError.sizeLimit }
            cursor = page.cursor
            if let cursor, !seen.insert(cursor).inserted { throw ReadStateSyncFailure.conflict }
        } while cursor != nil
        let latest = try await checkedStatus(viewer, epoch: expected)
        if latest.authority == .pds { try await engine.discardVerifiedMigration(); return }
        guard latest.legacyRevision == revision else { throw ReadStateSyncFailure.conflict }
        let current: RepoRecord<ReadStateManifest>? = try await xrpc.readStateRecord(viewerDid: viewer,
            collection: ReadStateManifest.collection, rkey: "self")
        try await check(viewer, epoch: expected)
        let operations = try ReadStateMigrationPlanner.operations(rows: rows,
            migrationId: "migration-\(revision ?? 0)")
        try await engine.replaceUnverifiedMigration(operations, legacyRevision: revision ?? 0,
            replacingManifestCid: current?.cid)
        try await engine.flush()
        let confirmed = try await checkedStatus(viewer, epoch: expected)
        guard confirmed.authority == .pds else { throw ReadStateSyncFailure.conflict }
    }

    private func engineForViewer(_ viewer: String) throws -> ReadStateSyncEngine {
        if let engine { return engine }
        if let engineProvider {
            let engine = try engineProvider(viewer)
            self.engine = engine
            return engine
        }
        let hash = SHA256.hash(data: Data(viewer.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appending(path: "ReadStateOutbox")
        let xrpc = xrpc
        let gateway = gateway
        let expected = epoch
        let verify: @Sendable () async throws -> Void = { [weak self] in
            guard let self else { throw ReadStateSyncFailure.accountChanged }
            try await self.check(viewer, epoch: expected)
        }
        let transport = ReadStateSyncTransport(
            readManifest: {
                try await verify()
                let record: RepoRecord<ReadStateManifest>? = try await xrpc.readStateRecord(viewerDid: viewer,
                    collection: ReadStateManifest.collection, rkey: "self")
                try await verify()
                return record.flatMap { record in record.cid.map { .init(manifest: record.value, cid: $0) } }
            }, loadProjection: { manifest in
                try await verify()
                return try await ReadStateGenerationLoader.load(manifest: manifest, viewerDid: viewer) { reference in
                    let key = String(reference.uri.split(separator: "/").last ?? "")
                    let record: RepoRecord<ReadStateChunk>? = try await xrpc.readStateRecord(viewerDid: viewer,
                        collection: ReadStateChunk.collection, rkey: key, cid: reference.cid)
                    guard let record else { throw ReadStateError.incompleteGeneration }
                    return record.value
                }
            }, putChunk: { key, chunk in
                try await verify()
                do {
                    return try await xrpc.putReadStateRecord(viewerDid: viewer, collection: ReadStateChunk.collection,
                        rkey: key, record: chunk, expectedCid: nil)
                } catch ReadStateSyncFailure.conflict {
                    let old: RepoRecord<ReadStateChunk>? = try await xrpc.readStateRecord(viewerDid: viewer,
                        collection: ReadStateChunk.collection, rkey: key)
                    guard let old, old.value == chunk, let cid = old.cid else { throw ReadStateSyncFailure.conflict }
                    return .init(uri: old.uri, cid: cid)
                }
            }, putManifest: { manifest, cid in
                try await verify()
                return try await xrpc.putReadStateRecord(viewerDid: viewer, collection: ReadStateManifest.collection,
                    rkey: "self", record: manifest, expectedCid: cid).cid
            }, confirm: { cid, revision in
                try await verify()
                let _: PDSReadStateStatus = try await gateway.pdsReadStateRequest("confirmReadState",
                    body: JSONEncoder().encode(ReadStateConfirmInput(manifestCid: cid, expectedLegacyRevision: revision)), expectedViewer: viewer)
                try await verify()
            })
        let engine = try ReadStateSyncEngine(viewerDid: viewer, file: directory.appending(path: hash + ".json"), transport: transport)
        self.engine = engine
        return engine
    }
}
