import Foundation

/// Serializes bootstrap NDJSON event side-effects and pending first-unread selection.
@MainActor
final class BootstrapStreamCoordinator {
    var pendingStreamedEntriesPage: BootstrapEntriesPagePayloadDTO?
    var pendingStreamSelectedPublicationId: String?
    private var selectionTask: Task<Void, Never>?

    func reset() {
        pendingStreamedEntriesPage = nil
        pendingStreamSelectedPublicationId = nil
        selectionTask?.cancel()
        selectionTask = nil
    }

    /// Queue a single pending-selection pass (replaces overlapping Tasks).
    func schedulePendingSelection(_ handler: @escaping @MainActor () async -> Void) {
        selectionTask?.cancel()
        selectionTask = Task { @MainActor in
            await handler()
        }
    }
}
