import Foundation

/// Application permission sets and collection-level OAuth scopes for the web SPA and native clients.
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
    "include:app.bsky.authCreatePosts?aud=did:web:api.bsky.app%23bsky_appview",
    "include:app.bsky.authDeleteContent?aud=did:web:api.bsky.app%23bsky_appview",
    "repo:app.bsky.feed.like?action=create",
    "repo:app.bsky.feed.repost?action=create",
    "repo:community.lexicon.bookmarks.bookmark?action=create&action=update&action=delete",
    "repo:link.latr.bookmarks.metadata?action=create&action=update&action=delete",
    "repo:link.latr.saved.external?action=delete",
    "repo:link.latr.saved.item?action=delete",
    "repo:com.latr.saved.external?action=delete",
    "repo:com.latr.saved.item?action=delete",
  ]

  private static let webOnlyScopes = [
    "include:site.standard.authSocial",
    "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
    "include:app.userinput.authFull",
    "blob:*/*",
  ]

  private static let iosOnlyScopes = [
    "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
    "repo:site.standard.graph.subscription?action=create&action=update&action=delete",
    "repo:app.bsky.feed.post?action=update",
  ]

  static let webScope = (sharedScopes + webOnlyScopes).joined(separator: " ")

  static let iosScope = (sharedScopes + iosOnlyScopes).joined(separator: " ")
}
