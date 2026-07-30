import { LATR_REPO_OAUTH_SCOPES } from "@/lib/latrCollections";

/**
 * Space-separated ATProto OAuth scopes. Must stay in sync with
 * `public/client-metadata.json` (`scope`) for API parity tests: authorization
 * servers reject undeclared scopes.
 *
 * `atproto` is required by the ATProto OAuth profile. Repository writes for
 * Social Wire lexicons need explicit `repo:` permissions.
 *
 * During the `com.thesocialwire.*` → `app.thesocialwire.*` transition, legacy
 * non-read-state repo scopes remain so clients can delete old records after migration.
 *
 * L@tr read-later uses canonical `link.latr.saved.*` with legacy `com.latr.*`
 * scopes retained for one-time repo migration.
 *
 * **Re-login required after deploy:** widening scopes does not upgrade existing
 * access tokens; users must sign out and sign in again.
 */
export const SOCIAL_WIRE_REPO_SCOPES = [
  "repo:app.thesocialwire.folder?action=create&action=update&action=delete",
  "repo:app.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
  "repo:app.thesocialwire.preferences?action=create&action=update&action=delete",
  "repo:com.thesocialwire.folder?action=create&action=update&action=delete",
  "repo:com.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
  "repo:com.thesocialwire.preferences?action=create&action=update&action=delete",
] as const;

export const BLUESKY_SOCIAL_REPO_SCOPES = [
  "repo:app.bsky.feed.post?action=create&action=delete",
  "repo:app.bsky.feed.like?action=create&action=delete",
  "repo:app.bsky.feed.repost?action=create&action=delete",
] as const;

export const STANDARD_SITE_SUBSCRIPTION_REPO_SCOPE =
  "repo:site.standard.graph.subscription?action=create&action=update&action=delete";

export const STANDARD_SITE_RECOMMEND_REPO_SCOPE =
  "repo:site.standard.graph.recommend?action=create&action=delete";

export const STANDARD_SITE_REPO_SCOPES = [
  STANDARD_SITE_SUBSCRIPTION_REPO_SCOPE,
  STANDARD_SITE_RECOMMEND_REPO_SCOPE,
] as const;

export const SKYREADER_REPO_SCOPES = [
  "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
] as const;

export const AT_PROTO_OAUTH_SCOPES = [
  "atproto",
  ...SOCIAL_WIRE_REPO_SCOPES,
  ...BLUESKY_SOCIAL_REPO_SCOPES,
  ...LATR_REPO_OAUTH_SCOPES,
  STANDARD_SITE_SUBSCRIPTION_REPO_SCOPE,
  ...SKYREADER_REPO_SCOPES,
  STANDARD_SITE_RECOMMEND_REPO_SCOPE,
].join(" ");
