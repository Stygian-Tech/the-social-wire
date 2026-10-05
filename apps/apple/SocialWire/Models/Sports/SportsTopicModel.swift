import Foundation
import Observation

@Observable
@MainActor
final class SportsTopicModel {
    private let gateway: SocialWireGatewayClient
    private let xrpc: XRPCClient
    private var viewer: String?
    private var requestEpoch = 0
    private var searchEpoch = 0
    private var selectionEpoch = 0
    private var catalogEpoch = 0
    private var eventEpoch = 0
    private var selectionsReconciled = true
    private(set) var catalog: SportsCatalog?
    private(set) var selectedFeedID = "sports"
    private(set) var items: [SportsFeedItem] = []
    private(set) var page: SportsPage?
    private(set) var selections: [SportsSelectionRecord] = []
    private(set) var searchResults: [SportsEntity] = []
    private(set) var eventScope = "all"
    var preferredEventIDs: [String] {
        SportsEntity.preferredIDs(entities: catalog?.entities ?? [], selections: selections, scope: eventScope)
    }
    var allPreferredEventIDs: [String] {
        SportsEntity.preferredIDs(entities: catalog?.entities ?? [], selections: selections, scope: "all")
    }
    private(set) var events: SportsEventsResponse?
    private(set) var error: String?
    private(set) var eventsError: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var continuationSuspended = false

    var selectedFeed: SportsNamedFeed? { catalog?.feeds.first { $0.id == selectedFeedID } }
    var selectedTitle: String { selectedFeed?.title ?? (selectedFeedID == "sports" ? "All Sports" : "Unavailable Sports Feed") }
    var fingerprint: String { selections.map { "\($0.reference):\($0.action)" }.sorted().joined(separator: "|") }

    init(gateway: SocialWireGatewayClient, xrpc: XRPCClient) {
        self.gateway = gateway
        self.xrpc = xrpc
        eventScope = Self.storedEventScope(viewer: nil)
    }

    func bind(viewer newViewer: String?) {
        guard viewer != newViewer else { return }
        viewer = newViewer
        selectionsReconciled = newViewer == nil
        eventScope = Self.storedEventScope(viewer: newViewer)
        requestEpoch += 1; searchEpoch += 1; selectionEpoch += 1; catalogEpoch += 1; eventEpoch += 1
        catalog = nil; selectedFeedID = "sports"; items = []; page = nil; selections = []; searchResults = []
        events = nil; error = nil; eventsError = nil; isLoading = false; isSaving = false; continuationSuspended = false
    }

    func loadCatalog() async {
        catalogEpoch += 1
        let epoch = catalogEpoch, currentViewer = viewer
        do {
            let value = try await gateway.fetchSportsCatalog()
            guard epoch == catalogEpoch, viewer == currentViewer else { return }
            catalog = value
        } catch {
            guard epoch == catalogEpoch, viewer == currentViewer else { return }
            self.error = error.localizedDescription
        }
    }

    func selectFeed(_ id: String, language: String) async {
        guard id != selectedFeedID, catalog?.feeds.contains(where: { $0.id == id }) == true else { return }
        requestEpoch += 1; eventEpoch += 1
        selectedFeedID = id; items = []; page = nil; events = nil; eventsError = nil; error = nil; continuationSuspended = false
        await load(language: language)
        await loadEvents()
    }

    func reconcileSelections() async throws {
        guard let currentViewer = viewer else { selectionsReconciled = true; return }
        let revision = selectionEpoch
        var records: [SportsSelectionRecord] = [], cursor: String?
        var observedCursors = Set<String>(), pages = 0
        repeat {
            let result: ListRecordsResponse<SportsSelectionRecord> = try await xrpc.listRecords(repo: currentViewer,
                collection: SportsSelectionRecord.collection, limit: 100, cursor: cursor, authorized: true)
            records += result.records.filter { $0.value.type == SportsSelectionRecord.collection && $0.uri == "at://\(currentViewer)/\(SportsSelectionRecord.collection)/\($0.value.key)" && ["follow", "mute"].contains($0.value.action) }.map(\.value)
            cursor = result.cursor
            pages += 1
            if let cursor, pages >= 20 || !observedCursors.insert(cursor).inserted {
                throw SocialWireError.badResponse("Sports Interests Could Not Be Reconciled")
            }
        } while cursor != nil
        guard viewer == currentViewer, selectionEpoch == revision else { return }
        selections = records
        selectionsReconciled = true
    }

    func load(language: String, cursor: String? = nil) async {
        if let cursor, continuationSuspended || page?.cursor != cursor { return }
        requestEpoch += 1
        let epoch = requestEpoch, currentViewer = viewer, feed = selectedFeedID, revision = selectionEpoch
        isLoading = true; error = nil
        defer { if epoch == requestEpoch { isLoading = false } }
        do {
            if cursor == nil { try await reconcileSelections() }
            guard epoch == requestEpoch, revision == selectionEpoch, viewer == currentViewer, feed == selectedFeedID else { return }
            let preferences = fingerprint
            let value = try await gateway.fetchSports(language: language, feed: feed, cursor: cursor)
            guard epoch == requestEpoch, revision == selectionEpoch, viewer == currentViewer,
                  preferences == fingerprint, feed == selectedFeedID, value.feedId == feed, value.language == language else { return }
            if cursor != nil, page?.generationId != value.generationId { return }
            if cursor == nil { items = value.items; continuationSuspended = false }
            else {
                let existing = Set(items.map(\.id))
                items += value.items.filter { !existing.contains($0.id) }
            }
            page = value
        } catch {
            guard epoch == requestEpoch, revision == selectionEpoch, viewer == currentViewer, feed == selectedFeedID else { return }
            if cursor != nil, case SocialWireError.cursorExpired = error { await load(language: language) }
            else { self.error = error.localizedDescription }
        }
    }

    private static func storedEventScope(viewer: String?) -> String {
        let suffix = viewer ?? "anonymous"
        if let scope = UserDefaults.standard.string(forKey: "the-social-wire.sports-events-scope.v1.\(suffix)"),
           ["all", "sports", "leagues", "teams"].contains(scope) { return scope }
        return UserDefaults.standard.bool(forKey: "the-social-wire.sports-events-teams.v1.\(suffix)") ? "teams" : "all"
    }

    func setEventScope(_ scope: String) async {
        guard ["all", "sports", "leagues", "teams"].contains(scope) else { return }
        eventScope = scope
        UserDefaults.standard.set(scope, forKey: "the-social-wire.sports-events-scope.v1.\(viewer ?? "anonymous")")
        events = nil; eventsError = nil
        await loadEvents()
    }

    func loadEvents() async {
        guard catalog?.eventsEnabled == true else { events = nil; return }
        guard selectionsReconciled || selectedFeedID != "sports" else {
            events = nil; eventsError = "Load Sports Interests Before Viewing Personalized Schedules"
            return
        }
        eventEpoch += 1
        let epoch = eventEpoch, feed = selectedFeedID, currentViewer = viewer, preference = fingerprint
        let dedicatedFeed = feed != "sports"
        let preferredIDs = dedicatedFeed ? [] : preferredEventIDs
        let teamIDs: [String]? = !dedicatedFeed && eventScope == "teams" ? preferredIDs : nil
        if !dedicatedFeed, eventScope != "all", preferredIDs.isEmpty {
            let category = eventScope == "sports" ? "Sports" : eventScope == "leagues" ? "Leagues or Competitions" : "Teams"
            events = nil; eventsError = "Follow \(category) to See Their Schedules and Standings"
            return
        }
        do {
            let zone = TimeZone.current.identifier
            let value = try await gateway.fetchSportsEvents(feed: feed, teamIDs: teamIDs,
                preferredIDs: preferredIDs, timeZone: zone)
            guard zone == TimeZone.current.identifier else { return }
            guard epoch == eventEpoch, feed == selectedFeedID, viewer == currentViewer, preference == fingerprint else { return }
            if !value.matchesOrderingContext(preferredIDs: preferredIDs, timeZone: zone) {
                events = nil; eventsError = "Personalized Schedules Are Temporarily Unavailable"
                return
            }
            if let teamIDs, !value.matchesTeamScope(teamIDs) {
                events = nil; eventsError = "Team Schedules Are Temporarily Unavailable"
                return
            }
            events = value; eventsError = nil
        } catch {
            guard epoch == eventEpoch, feed == selectedFeedID, viewer == currentViewer, preference == fingerprint else { return }
            eventsError = "Event Data Is Temporarily Unavailable"
        }
    }

    func search(_ query: String) async {
        searchEpoch += 1
        let epoch = searchEpoch, currentViewer = viewer
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searchResults = []; return }
        do {
            let value = try await gateway.searchSportsEntities(query: query)
            guard epoch == searchEpoch, currentViewer == viewer else { return }
            searchResults = value.filter(\.isSelectable)
        } catch {
            guard epoch == searchEpoch, currentViewer == viewer else { return }
            self.error = error.localizedDescription
        }
    }

    func setSelection(reference: String, action: String?) async {
        guard let currentViewer = viewer, !isSaving, action == nil || ["follow", "mute"].contains(action!),
              action == nil || catalog?.entities.contains(where: { $0.id == reference && $0.isSelectable }) == true || searchResults.contains(where: { $0.id == reference && $0.isSelectable }) else { return }
        isSaving = true; selectionEpoch += 1; requestEpoch += 1; eventEpoch += 1
        events = nil
        let revision = selectionEpoch, feed = selectedFeedID, oldSelections = selections, oldItems = items, oldSuspension = continuationSuspended
        let existing = selections.first { $0.reference == reference }
        selections.removeAll { $0.reference == reference }
        let now = ISO8601DateFormatter().string(from: Date())
        let record = action.map { SportsSelectionRecord(reference: reference, action: $0, createdAt: existing?.createdAt ?? now, updatedAt: now) }
        if let record { selections.append(record) }
        continuationSuspended = true; isLoading = false
        items = SportsPersonalization.reorder(items, selections: selections, global: feed == "sports")
        defer { if viewer == currentViewer, revision == selectionEpoch { isSaving = false } }
        do {
            if let record { try await xrpc.putRecord(collection: SportsSelectionRecord.collection, rkey: record.key, record: record, expectedViewer: currentViewer) }
            else { try await xrpc.deleteRecord(collection: SportsSelectionRecord.collection, rkey: SportsSelectionRecord.key(reference: reference), expectedViewer: currentViewer) }
        } catch {
            guard viewer == currentViewer, revision == selectionEpoch else { return }
            selections = oldSelections
            if selectedFeedID == feed { items = oldItems; continuationSuspended = oldSuspension }
            self.error = "Couldn't Save Sports Interest. " + error.localizedDescription
        }
        await loadEvents()
    }
}
