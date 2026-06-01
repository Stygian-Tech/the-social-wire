/**
 * Space-separated ATProto OAuth scopes. Must stay in sync with
 * `public/client-metadata.json` (`scope`) for API parity tests: authorization
 * servers reject undeclared scopes.
 *
 * `atproto` is required by the ATProto OAuth profile. Repository writes for
 * Social Wire lexicons need explicit `repo:` permissions.
 *
 * During the `com.thesocialwire.*` → `app.thesocialwire.*` transition, legacy
 * repo scopes remain so clients can delete old records after migration.
 *
 * **Re-login required after deploy:** widening scopes does not upgrade existing
 * access tokens; users must sign out and sign in again.
 */
export const AT_PROTO_OAUTH_SCOPES = [
  "atproto",
  "repo:app.thesocialwire.folder?action=create&action=update&action=delete",
  "repo:app.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
  "repo:app.thesocialwire.preferences?action=create&action=update&action=delete",
  "repo:app.thesocialwire.entryReadState?action=create&action=update&action=delete",
  "repo:com.thesocialwire.folder?action=create&action=update&action=delete",
  "repo:com.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
  "repo:com.thesocialwire.preferences?action=create&action=update&action=delete",
  "repo:com.thesocialwire.entryReadState?action=create&action=update&action=delete",
  "repo:com.latr.saved.external?action=create&action=update&action=delete",
  "repo:com.latr.saved.item?action=create&action=update&action=delete",
  "repo:site.standard.graph.subscription?action=create&action=update&action=delete",
  "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
].join(" ");
