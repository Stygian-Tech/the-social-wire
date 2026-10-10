import { STANDARD_READER_LIST_SAVE_SCOPE, STANDARD_READER_LIST_WRITE_SCOPE } from "@/lib/standardReaderList";
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
  "repo:app.thesocialwire.finance.selection?action=create&action=update&action=delete",
  "repo:app.thesocialwire.sports.selection?action=create&action=update&action=delete",
  "repo:com.thesocialwire.folder?action=create&action=update&action=delete",
  "repo:com.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
  "repo:com.thesocialwire.preferences?action=create&action=update&action=delete",
] as const;

export const BLUESKY_SOCIAL_PERMISSION_SCOPES = [
  "include:app.bsky.authCreatePosts?aud=did:web:api.bsky.app%23bsky_appview",
  "include:app.bsky.authDeleteContent?aud=did:web:api.bsky.app%23bsky_appview",
] as const;

/** Article drafts stay private; these permissions publish finished native records. */
export const ARTICLE_PUBLISHING_SCOPES = [
  "repo:site.standard.document?action=create&action=update",
  "repo:app.offprint.document.article?action=create&action=update",
  "repo:blog.pckt.document?action=create&action=update",
  "blob:text/markdown",
  "blob:application/json",
] as const;

export const BLUESKY_SOCIAL_REPO_SCOPES = [
  "repo:app.bsky.graph.list?action=create&action=update&action=delete",
  "repo:app.bsky.graph.listitem?action=create&action=delete",
  "repo:app.bsky.feed.like?action=create",
  "repo:app.bsky.feed.repost?action=create",
] as const;

/** Authenticated Social reads are routed through the viewer PDS AppView proxy. */
export const BLUESKY_SOCIAL_RPC_SCOPES = [
  "rpc:app.bsky.actor.getProfile?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.bookmark.getBookmarks?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.bookmark.createBookmark?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.bookmark.deleteBookmark?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.feed.searchPosts?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.actor.searchActors?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.actor.getSuggestions?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.notification.listNotifications?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.notification.getUnreadCount?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.notification.updateSeen?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.feed.getPosts?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.graph.getLists?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.actor.putPreferences?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.feed.getSuggestedFeeds?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.unspecced.getPopularFeedGenerators?aud=did:web:api.bsky.app%23bsky_appview",

  "rpc:app.bsky.feed.getPostThread?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.feed.getAuthorFeed?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.feed.getActorLikes?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.feed.getTimeline?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.feed.getFeed?aud=did:web:api.bsky.app%23bsky_appview",
  // PDS getFeed delegates to the generator and separately authorizes its skeleton RPC.
  "rpc:app.bsky.feed.getFeedSkeleton?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.feed.getFeedGenerators?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.feed.getListFeed?aud=did:web:api.bsky.app%23bsky_appview",
  "rpc:app.bsky.labeler.getServices?aud=did:web:api.bsky.app%23bsky_appview",
] as const;

export const BLUESKY_CHAT_RPC_SCOPES = [
  "rpc:chat.bsky.convo.listConvos?aud=did:web:api.bsky.chat%23bsky_chat",
  "rpc:chat.bsky.convo.getMessages?aud=did:web:api.bsky.chat%23bsky_chat",
  "rpc:chat.bsky.convo.getConvoForMembers?aud=did:web:api.bsky.chat%23bsky_chat",
  "rpc:chat.bsky.convo.sendMessage?aud=did:web:api.bsky.chat%23bsky_chat",
  "rpc:chat.bsky.convo.updateRead?aud=did:web:api.bsky.chat%23bsky_chat",
  "rpc:chat.bsky.convo.deleteMessageForSelf?aud=did:web:api.bsky.chat%23bsky_chat",
  "rpc:chat.bsky.convo.muteConvo?aud=did:web:api.bsky.chat%23bsky_chat",
  "rpc:chat.bsky.convo.unmuteConvo?aud=did:web:api.bsky.chat%23bsky_chat",
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

export const PDS_READ_STATE_REPO_SCOPES = [
  "repo:app.thesocialwire.readState?action=create&action=update&action=delete",
  "repo:app.thesocialwire.readStateChunk?action=create&action=update&action=delete",
] as const;

export const AT_PROTO_OAUTH_SCOPES = [
  ...PDS_READ_STATE_REPO_SCOPES,
  "atproto",
  ...SOCIAL_WIRE_REPO_SCOPES,
  ...ARTICLE_PUBLISHING_SCOPES,
  ...BLUESKY_SOCIAL_PERMISSION_SCOPES,
  ...BLUESKY_SOCIAL_RPC_SCOPES,
  ...BLUESKY_CHAT_RPC_SCOPES,
  ...WIRE_MODERATION_RPC_SCOPES,
  ...BLUESKY_SOCIAL_REPO_SCOPES,
  ...LATR_REPO_OAUTH_SCOPES,
  ...SEMBLE_REPO_OAUTH_SCOPES,
  WIRE_FEEDBACK_REPO_SCOPE,
  STANDARD_SITE_SOCIAL_PERMISSION_SCOPE,
  ...SKYREADER_REPO_SCOPES,
  STANDARD_READER_LIST_SAVE_SCOPE,
  STANDARD_READER_LIST_WRITE_SCOPE,
  USER_INPUT_OAUTH_SCOPE,
  USER_INPUT_BLOB_OAUTH_SCOPE,
  "repo:app.thesocialwire.podcast.clip?action=create&action=update&action=delete",
].join(" ");
