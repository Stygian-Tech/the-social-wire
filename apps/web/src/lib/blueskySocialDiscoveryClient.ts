import { AppBskyFeedPost, type AppBskyActorDefs, type AppBskyFeedDefs, type AppBskyNotificationListNotifications, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent, socialErrorMessage } from "./blueskySocialClient";
import { socialReplyMetadata } from "./socialReplyMetadata";

export type SocialExploreKind = "posts" | "people";
export type SocialExplorePage = { posts: AppBskyFeedDefs.PostView[]; actors: AppBskyActorDefs.ProfileView[]; cursor?: string };
export type SocialNotification = AppBskyNotificationListNotifications.Notification;
export type SocialNotificationPage = { notifications: SocialNotification[]; posts: AppBskyFeedDefs.PostView[]; unavailablePostUris?: string[]; cursor?: string; seenAt?: string };

/** Use the loaded unread boundary, allowing equivalent RFC 3339 formats. */
export function notificationReadBoundary(notifications: readonly SocialNotification[]): string | undefined {
  let latest = -Infinity;
  for (const notification of notifications) {
    if (!notification.isRead) latest = Math.max(latest, Date.parse(notification.indexedAt));
  }
  return Number.isFinite(latest) ? new Date(latest).toISOString() : undefined;
}

function agentFor(session: OAuthSession, moderation: ModerationOpts) {
  if (moderation.userDid !== session.did) throw new Error("Your account changed. Please reload this page.");
  const agent = createAuthenticatedAppViewAgent(session);
  agent.configureLabelers(moderation.prefs.labelers.map(labeler => labeler.did));
  return agent;
}

export async function getSocialExplorePage(args: { session: OAuthSession; moderation: ModerationOpts; query: string; kind: SocialExploreKind; cursor?: string; signal?: AbortSignal }): Promise<SocialExplorePage> {
  const agent = agentFor(args.session, args.moderation);
  const q = args.query.trim();
  const options = { signal: args.signal };
  const pagination = { cursor: args.cursor, limit: 25 };
  if (!q) {
    const result = await agent.app.bsky.actor.getSuggestions(pagination, options);
    return { actors: result.data.actors, posts: [], cursor: result.data.cursor };
  }
  if (args.kind === "people") {
    const result = await agent.app.bsky.actor.searchActors({ ...pagination, q }, options);
    return { actors: result.data.actors, posts: [], cursor: result.data.cursor };
  }
  const result = await agent.app.bsky.feed.searchPosts({ ...pagination, q, sort: "latest" }, options);
  return { actors: [], posts: result.data.posts, cursor: result.data.cursor };
}

export function notificationPostUri(notification: SocialNotification): string | undefined {
  let uri: unknown;
  // Reply notifications identify the reply itself. reasonSubject and the
  // record reply.parent/root are context, never substitutes for its target.
  if (["mention", "reply", "quote", "subscribed-post"].includes(notification.reason)) uri = notification.uri;
  else if (["like", "repost", "like-via-repost", "repost-via-repost"].includes(notification.reason)) {
    const subject = notification.record.subject;
    uri = notification.reasonSubject ?? (subject && typeof subject === "object" && "uri" in subject ? subject.uri : undefined);
  }
  return typeof uri === "string" && /^at:\/\/did:[^/]+\/app\.bsky\.feed\.post\/[^/?#]+$/.test(uri) ? uri : undefined;
}

/** Reply context is the immediate parent; thread roots are never hydrated as substitutes. */
export function notificationReplyParentUri(notification: SocialNotification): string | undefined {
  if (notification.reason !== "reply") return undefined;
  const record = AppBskyFeedPost.validateRecord(notification.record);
  const uri = record.success ? record.value.reply?.parent.uri : undefined;
  return uri && /^at:\/\/did:[^/]+\/app\.bsky\.feed\.post\/[^/?#]+$/.test(uri) ? uri : undefined;
}

export function notificationFeedItem(notification: SocialNotification, posts: ReadonlyMap<string, AppBskyFeedDefs.PostView>, unavailablePosts: ReadonlySet<string> = new Set()): AppBskyFeedDefs.FeedViewPost | undefined {
  const uri = notificationPostUri(notification);
  const post = uri ? posts.get(uri) : undefined;
  if (!post) return undefined;
  const parentUri = notificationReplyParentUri(notification);
  const record = AppBskyFeedPost.validateRecord(notification.record);
  if (!parentUri || parentUri === post.uri || !record.success || !record.value.reply) return { post };
  return { post, reply: socialReplyMetadata({ post: { ...post, record: record.value } }, posts, unavailablePosts) };
}

export async function getSocialNotificationsPage(args: { session: OAuthSession; moderation: ModerationOpts; cursor?: string; signal?: AbortSignal }): Promise<SocialNotificationPage> {
  const agent = agentFor(args.session, args.moderation);
  const options = { signal: args.signal };
  const result = await agent.app.bsky.notification.listNotifications({ cursor: args.cursor, limit: 30 }, options);
  args.signal?.throwIfAborted();
  const uris = [...new Set(result.data.notifications.flatMap(notification => [notificationPostUri(notification), notificationReplyParentUri(notification)]).filter((uri): uri is string => !!uri))];
  const posts: AppBskyFeedDefs.PostView[] = [];
  const unavailablePostUris: string[] = [];
  for (let index = 0; index < uris.length; index += 25) {
    const requested = uris.slice(index, index + 25);
    const page = await agent.app.bsky.feed.getPosts({ uris: requested }, options);
    args.signal?.throwIfAborted();
    // Ignore unexpected hydration results; a missing reply stays unavailable.
    posts.push(...page.data.posts.filter(post => requested.includes(post.uri)));
    const returned = new Set(page.data.posts.map(post => post.uri));
    unavailablePostUris.push(...requested.filter(uri => !returned.has(uri)));
  }
  return { ...result.data, posts, unavailablePostUris };
}

export async function getSocialNotificationUnread(session: OAuthSession, signal?: AbortSignal): Promise<number> {
  const result = await createAuthenticatedAppViewAgent(session).app.bsky.notification.getUnreadCount({}, { signal });
  return result.data.count;
}

export async function markSocialNotificationsSeen(session: OAuthSession, seenAt: string): Promise<void> {
  await createAuthenticatedAppViewAgent(session).app.bsky.notification.updateSeen({ seenAt });
}

export function nextDiscoveryCursor(page: { cursor?: string }, pageParams: readonly unknown[]): string | undefined {
  return page.cursor && !pageParams.includes(page.cursor) ? page.cursor : undefined;
}

export function notificationIdentity(notification: SocialNotification): string {
  return `${notification.uri}:${notification.reason}:${notification.author.did}:${notification.indexedAt}`;
}

export function socialDiscoveryErrorMessage(error: unknown, feature: "Explore" | "Notifications"): string {
  if (error && typeof error === "object") {
    const code = "error" in error ? error.error : undefined;
    const status = "status" in error ? error.status : undefined;
    if (status === 501 || ["MethodNotImplemented", "MethodNotFound", "XRPCNotSupported", "NotImplemented", "UnsupportedMethod"].includes(String(code))) return `${feature} is not supported by this server.`;
  }
  const message = socialErrorMessage(error);
  return message === "This social feed could not be loaded. Please retry." ? `${feature} could not be loaded. Please retry.` : message;
}
