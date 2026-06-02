import Foundation

/// Single source for OAuth scopes shared by web SPA + native ATS clients.
///
/// Mirrors `apps/web/public/client-metadata.json` and MUST stay lexically aligned—API tests golden-file that JSON.
/// During the `com.thesocialwire.*` → `app.thesocialwire.*` transition, legacy repo scopes remain so clients can delete old records.
public enum ATProtoOAuthScopes {
  static let scope =
    [
      "atproto",
      "repo:app.thesocialwire.folder?action=create&action=update&action=delete",
      "repo:app.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
      "repo:app.thesocialwire.preferences?action=create&action=update&action=delete",
      "repo:app.thesocialwire.entryReadState?action=create&action=update&action=delete",
      "repo:com.thesocialwire.folder?action=create&action=update&action=delete",
      "repo:com.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
      "repo:com.thesocialwire.preferences?action=create&action=update&action=delete",
      "repo:com.thesocialwire.entryReadState?action=create&action=update&action=delete",
      "repo:link.latr.saved.external?action=create&action=update&action=delete",
      "repo:link.latr.saved.item?action=create&action=update&action=delete",
      "repo:com.latr.saved.external?action=create&action=update&action=delete",
      "repo:com.latr.saved.item?action=create&action=update&action=delete",
      "repo:site.standard.graph.subscription?action=create&action=update&action=delete",
      "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
    ]
    .joined(separator: " ")
}
