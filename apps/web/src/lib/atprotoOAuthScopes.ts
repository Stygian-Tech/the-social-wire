import { LATR_REPO_OAUTH_SCOPES } from "@/lib/latrCollections";
import {
  USER_INPUT_BLOB_OAUTH_SCOPE,
  USER_INPUT_OAUTH_SCOPE,
} from "@/lib/userInputFeedback";

/**
 * Space-separated ATProto OAuth scopes. Must stay in sync with
 * `public/client-metadata.json` (`scope`) for API parity tests: authorization
 * servers reject undeclared scopes.
 *
 * `atproto` is required by the ATProto OAuth profile. Prefer published
 * application permission sets so PDS consent screens can group permissions by
 * product. Keep explicit `repo:` grants only where no suitable set exists.
 *
 * During the `com.thesocialwire.*` → `app.thesocialwire.*` transition, legacy
 * non-read-state repo scopes remain so clients can delete old records after migration.
 *
 * L@tr uses community bookmarks plus `link.latr.bookmarks.metadata`; legacy
 * wrapper collections retain delete-only grants for one-time migration.
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

export const BLUESKY_SOCIAL_PERMISSION_SCOPES = [
  "include:app.bsky.authCreatePosts?aud=did:web:api.bsky.app%23bsky_appview",
  "include:app.bsky.authDeleteContent?aud=did:web:api.bsky.app%23bsky_appview",
] as const;

export const BLUESKY_SOCIAL_REPO_SCOPES = [
  "repo:app.bsky.feed.like?action=create",
  "repo:app.bsky.feed.repost?action=create",
] as const;

/** Viewer moderation reads used by authenticated The Wire requests. */
export const WIRE_MODERATION_RPC_SCOPES = [
  "rpc:app.bsky.actor.getPreferences?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.graph.getBlocks?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.graph.getMutes?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.graph.getListMutes?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.graph.getListBlocks?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.graph.getList?aud=did:web:api.bsky.app%23bsky_appview",
] as const;

export const STANDARD_SITE_SOCIAL_PERMISSION_SCOPE =
  "include:site.standard.authSocial";

export const WIRE_FEEDBACK_REPO_SCOPE =
  "repo:app.thesocialwire.wireFeedback?action=create&action=update&action=delete";

export const SKYREADER_REPO_SCOPES = [
  "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
] as const;

/** Direct viewer-PDS writes used by the Semble Read Later provider. */
export const SEMBLE_REPO_OAUTH_SCOPES = [
  "repo:network.cosmik.card?action=create&action=update&action=delete",
  "repo:network.cosmik.collection?action=create&action=update&action=delete",
  "repo:network.cosmik.collectionLink?action=create&action=update&action=delete",
  "repo:network.cosmik.collectionLinkRemoval?action=create&action=update&action=delete",
  "repo:network.cosmik.connection?action=create&action=update&action=delete",
] as const;

export const AT_PROTO_OAUTH_SCOPES = [
  "atproto",
  ...SOCIAL_WIRE_REPO_SCOPES,
  ...BLUESKY_SOCIAL_PERMISSION_SCOPES,
  ...WIRE_MODERATION_RPC_SCOPES,
  ...BLUESKY_SOCIAL_REPO_SCOPES,
  ...LATR_REPO_OAUTH_SCOPES,
  ...SEMBLE_REPO_OAUTH_SCOPES,
  WIRE_FEEDBACK_REPO_SCOPE,
  STANDARD_SITE_SOCIAL_PERMISSION_SCOPE,
  ...SKYREADER_REPO_SCOPES,
  USER_INPUT_OAUTH_SCOPE,
  USER_INPUT_BLOB_OAUTH_SCOPE,
].join(" ");
