import Foundation

public struct LexiconMigrationSummary: Sendable, Equatable, Codable {
  public var foldersCopied: Int
  public var publicationPrefsCopied: Int
  public var preferencesCopied: Int
  public var entryReadStateCopied: Int
  public var foldersDeleted: Int
  public var publicationPrefsDeleted: Int
  public var preferencesDeleted: Int
  public var entryReadStateDeleted: Int

  public init(
    foldersCopied: Int = 0,
    publicationPrefsCopied: Int = 0,
    preferencesCopied: Int = 0,
    entryReadStateCopied: Int = 0,
    foldersDeleted: Int = 0,
    publicationPrefsDeleted: Int = 0,
    preferencesDeleted: Int = 0,
    entryReadStateDeleted: Int = 0
  ) {
    self.foldersCopied = foldersCopied
    self.publicationPrefsCopied = publicationPrefsCopied
    self.preferencesCopied = preferencesCopied
    self.entryReadStateCopied = entryReadStateCopied
    self.foldersDeleted = foldersDeleted
    self.publicationPrefsDeleted = publicationPrefsDeleted
    self.preferencesDeleted = preferencesDeleted
    self.entryReadStateDeleted = entryReadStateDeleted
  }

  public var changed: Bool {
    foldersCopied > 0
      || publicationPrefsCopied > 0
      || preferencesCopied > 0
      || entryReadStateCopied > 0
      || foldersDeleted > 0
      || publicationPrefsDeleted > 0
      || preferencesDeleted > 0
      || entryReadStateDeleted > 0
  }
}

public enum LexiconMigration {
  private static let preferencesRKey = "self"

  /// Copies legacy `com.thesocialwire.*` records into `app.thesocialwire.*` and deletes the old rows.
  public static func migrateLegacyLexiconsIfNeeded(
    repo: ATProtoAuthenticatedRepoClient,
    auth: AuthContext
  ) async throws -> LexiconMigrationSummary {
    var summary = LexiconMigrationSummary()

    for pair in PublicationLexicons.legacyCollections {
      let legacyProbe = try await repo.listRecords(
        auth: auth,
        repo: auth.did,
        collection: pair.legacy,
        limit: 1
      )
      guard !legacyProbe.records.isEmpty else { continue }

      let legacyRecords = try await repo.listAllRecords(
        auth: auth,
        repo: auth.did,
        collection: pair.legacy
      )

      for record in legacyRecords {
        guard let rkey = rkeyFromUri(record.uri) else { continue }

        let existing = try await repo.getRecord(
          auth: auth,
          repo: auth.did,
          collection: pair.current,
          rkey: rkey
        )

        if existing == nil {
          var migrated = record.value.values
          migrated["$type"] = pair.current
          if pair.legacy == PublicationLexicons.legacyFolder {
            try await repo.putRecord(
              auth: auth,
              collection: pair.current,
              rkey: rkey,
              record: migrated
            )
            summary.foldersCopied += 1
          } else if pair.legacy == PublicationLexicons.legacyPublicationPrefs {
            try await repo.putRecord(
              auth: auth,
              collection: pair.current,
              rkey: rkey,
              record: migrated
            )
            summary.publicationPrefsCopied += 1
          } else if pair.legacy == PublicationLexicons.legacyPreferences {
            try await repo.putRecord(
              auth: auth,
              collection: pair.current,
              rkey: preferencesRKey,
              record: migrated
            )
            summary.preferencesCopied += 1
          } else if pair.legacy == PublicationLexicons.legacyEntryReadState {
            try await repo.putRecord(
              auth: auth,
              collection: pair.current,
              rkey: rkey,
              record: migrated
            )
            summary.entryReadStateCopied += 1
          }
        }

        try await repo.deleteRecord(auth: auth, collection: pair.legacy, rkey: rkey)

        switch pair.legacy {
        case PublicationLexicons.legacyFolder:
          summary.foldersDeleted += 1
        case PublicationLexicons.legacyPublicationPrefs:
          summary.publicationPrefsDeleted += 1
        case PublicationLexicons.legacyPreferences:
          summary.preferencesDeleted += 1
        case PublicationLexicons.legacyEntryReadState:
          summary.entryReadStateDeleted += 1
        default:
          break
        }
      }
    }

    return summary
  }

  private static func rkeyFromUri(_ uri: String) -> String? {
    guard let last = uri.split(separator: "/").last else { return nil }
    let rkey = String(last)
    return rkey.isEmpty ? nil : rkey
  }
}
