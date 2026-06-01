import Foundation

/// Collection NSIDs shared by gateway writes and appview projection reads.
public enum PublicationLexicons {
  public static let folder = "app.thesocialwire.folder"
  public static let publicationPrefs = "app.thesocialwire.publicationPrefs"
  public static let graphSubscription = "site.standard.graph.subscription"
  public static let skyreaderFeedSubscription = "app.skyreader.feed.subscription"
  public static let graphFollow = "app.bsky.graph.follow"
  public static let entryReadState = "app.thesocialwire.entryReadState"
  public static let preferences = "app.thesocialwire.preferences"

  public static let legacyFolder = "com.thesocialwire.folder"
  public static let legacyPublicationPrefs = "com.thesocialwire.publicationPrefs"
  public static let legacyEntryReadState = "com.thesocialwire.entryReadState"
  public static let legacyPreferences = "com.thesocialwire.preferences"

  public static let legacyCollections: [(legacy: String, current: String)] = [
    (legacyFolder, folder),
    (legacyPublicationPrefs, publicationPrefs),
    (legacyPreferences, preferences),
    (legacyEntryReadState, entryReadState),
  ]

  public static let publicationRecordCollections: Set<String> = [
    "site.standard.publication",
    "com.standard.publication",
  ]

  public static let discoveryPublicationCollections = [
    "site.standard.publication",
    "com.standard.publication",
    "app.offprint.publication",
  ]

  public static let discoveryContentCollections = [
    "site.standard.document",
    "com.standard.document",
    "site.standard.entry",
    "com.standard.entry",
  ]

  public static let rssAuthorDid = "did:web:skyreader.rss"
  public static let rssPublicationPrefix = "rss:"
}
