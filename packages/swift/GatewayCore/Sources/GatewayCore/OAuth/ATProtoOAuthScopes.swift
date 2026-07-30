import Foundation

/// Collection-level OAuth scopes for the web SPA and native clients.
///
/// Web scopes mirror `apps/web/public/client-metadata.json`; client-only actions stay limited
/// to the client that exposes them.
/// During the `com.thesocialwire.*` → `app.thesocialwire.*` transition, legacy non-read-state repo scopes remain so clients can delete old records.
public enum ATProtoOAuthScopes {
  private static let sharedScopes = [
    "atproto",
    "repo:app.thesocialwire.folder?action=create&action=update&action=delete",
    "repo:app.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
    "repo:app.thesocialwire.preferences?action=create&action=update&action=delete",
    "repo:com.thesocialwire.folder?action=create&action=update&action=delete",
    "repo:com.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
    "repo:com.thesocialwire.preferences?action=create&action=update&action=delete",
    "repo:app.bsky.feed.post?action=create&action=delete",
    "repo:app.bsky.feed.like?action=create&action=delete",
    "repo:app.bsky.feed.repost?action=create&action=delete",
    "repo:link.latr.saved.external?action=create&action=update&action=delete",
    "repo:link.latr.saved.item?action=create&action=update&action=delete",
    "repo:com.latr.saved.external?action=create&action=update&action=delete",
    "repo:com.latr.saved.item?action=create&action=update&action=delete",
    "repo:site.standard.graph.subscription?action=create&action=update&action=delete",
    "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
  ]

  private static let webOnlyScopes = [
    "repo:site.standard.graph.recommend?action=create&action=delete"
  ]

  static let webScope = (sharedScopes + webOnlyScopes).joined(separator: " ")

  static let iosScope = sharedScopes.joined(separator: " ")
}
