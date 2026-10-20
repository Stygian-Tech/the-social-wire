import { SKEJ_SCHEDULING_SCOPES } from "@/lib/skej/skejEnvironment";
import { BLUESKY_DRAFT_RPC_SCOPES, BLUESKY_SOCIAL_RPC_SCOPES, WIRE_MODERATION_RPC_SCOPES } from "@/lib/atprotoOAuthScopes";

const brandMethods = new Set([
  "app.bsky.actor.getProfile", "app.bsky.actor.searchActors",
  "app.bsky.notification.listNotifications", "app.bsky.notification.getUnreadCount", "app.bsky.notification.updateSeen",
  "app.bsky.feed.getPosts", "app.bsky.feed.getPostThread", "app.bsky.feed.getAuthorFeed", "app.bsky.labeler.getServices",
]);

/** Linked brands consent only to composing and audience engagement, never Reader or Tools writes. */
export const BRAND_ACCOUNT_OAUTH_SCOPES = [
  "atproto",
  "repo:app.bsky.feed.post?action=create",
  "repo:app.bsky.feed.like?action=create&action=delete",
  "repo:app.bsky.feed.repost?action=create&action=delete",
  "blob:image/*",
  ...BLUESKY_SOCIAL_RPC_SCOPES.filter(scope => brandMethods.has(scope.slice(4).split("?", 1)[0])),
  ...BLUESKY_DRAFT_RPC_SCOPES,
  ...WIRE_MODERATION_RPC_SCOPES,
  ...SKEJ_SCHEDULING_SCOPES,
].join(" ");
