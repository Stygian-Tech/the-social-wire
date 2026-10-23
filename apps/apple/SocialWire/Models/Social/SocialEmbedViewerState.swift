import Foundation
import Observation

/// One paginated viewer snapshot shared by every article card in the feed.
@Observable
@MainActor
final class SocialEmbedViewerState {
    private(set) var subscriptions: [RepoRecord<PublicationSubscriptionRecord>] = []
    private(set) var recommendations = Set<String>()
    private(set) var context: UUID?
    private(set) var revision = UUID()
    private(set) var ready = false
    private(set) var error: String?
    var updating = false
    @ObservationIgnored private var task: Task<Void, Never>?

    struct Snapshot {
        let subscriptions: [RepoRecord<PublicationSubscriptionRecord>]
        let recommendations: Set<String>
    }

    @ObservationIgnored private var requestID: UUID?

    func invalidate() {
        revision = UUID()
        task?.cancel()
        task = nil
        requestID = nil
        ready = false
    }

    func load(model: SocialWireAppModel, force: Bool = false) async {
        let epoch = model.socialEmbedContextID
        await load(context: epoch, force: force, isCurrent: { model.socialEmbedContextID == epoch }) {
            var records: [RepoRecord<PublicationSubscriptionRecord>] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                let page: ListRecordsResponse<PublicationSubscriptionRecord> = try await model.xrpc.listRecords(
                    repo: "", collection: PDSRecordService.standardSiteSubscription,
                    cursor: cursor, authorized: true)
                guard !Task.isCancelled, model.socialEmbedContextID == epoch else { throw CancellationError() }
                records.append(contentsOf: page.records)
                cursor = page.cursor
                if let cursor, !seen.insert(cursor).inserted {
                    throw SocialWireError.badResponse("Subscription pagination did not advance.")
                }
            } while cursor != nil
            let recommends = try await model.pds.listStandardSiteRecommendations()
            return Snapshot(subscriptions: records, recommendations: Set(recommends.map(\.value.document)))
        }
    }

    func load(context current: UUID, force: Bool = false,
              isCurrent: @escaping @MainActor () -> Bool,
              fetch: @escaping @MainActor () async throws -> Snapshot) async {
        if context != current {
            invalidate()
            subscriptions = []
            recommendations = []
            updating = false
            error = nil
            context = current
        }
        if let task { await task.value; return }
        if ready && !force { return }
        ready = false
        error = nil
        let identity = UUID()
        requestID = identity
        let work = Task { @MainActor in
            do {
                let snapshot = try await fetch()
                guard !Task.isCancelled, isCurrent(), context == current, requestID == identity else { return }
                subscriptions = snapshot.subscriptions
                recommendations = snapshot.recommendations
                ready = true
            } catch {
                guard !Task.isCancelled, isCurrent(), context == current, requestID == identity else { return }
                self.error = "Couldn't load publication actions. Try again."
            }
        }
        task = work
        await work.value
        if requestID == identity { task = nil; requestID = nil }
    }

    func failedMutation() {
        ready = false
        error = "Couldn't update publication actions. Refresh before trying again."
    }
}
