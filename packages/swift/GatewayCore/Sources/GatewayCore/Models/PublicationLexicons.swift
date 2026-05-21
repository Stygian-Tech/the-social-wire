import Foundation

/// Collection NSIDs shared by gateway writes and appview projection reads.
public enum PublicationLexicons {
  public static let folder = "com.thesocialwire.folder"
  public static let publicationPrefs = "com.thesocialwire.publicationPrefs"
  public static let graphSubscription = "site.standard.graph.subscription"
  public static let skyreaderFeedSubscription = "app.skyreader.feed.subscription"
  public static let graphFollow = "app.bsky.graph.follow"
  public static let entryReadState = "com.thesocialwire.entryReadState"
  public static let preferences = "com.thesocialwire.preferences"

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
