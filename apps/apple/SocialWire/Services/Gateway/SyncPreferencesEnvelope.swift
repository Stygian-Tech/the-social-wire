import Foundation

/// JSON bundle returned by **`app.thesocialwire.sync.getPreferences`** (`PreferenceSyncService.finalizePreferences`).
struct SyncPreferencesEnvelope: Codable, Sendable {
    let etag: String?
    let revision: String?
    let cid: String?
    let cachedAt: String?
    let record: PreferencesRecord?
}
