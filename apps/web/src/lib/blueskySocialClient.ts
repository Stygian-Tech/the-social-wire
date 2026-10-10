import { Agent, AppBskyFeedDefs, moderateFeedGenerator, moderateUserList, type ModerationDecision, type AppBskyActorDefs, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";
import { LocalAppViewAgent } from "@/lib/localAppViewAgent";
import { isMissingOAuthScope, SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export type SocialFeed = {
  kind: "following" | "feed" | "list";
  uri: string;
  name: string;
  pinned: boolean;
};

export const SOCIAL_FOLLOWING_FEED: SocialFeed = {
  kind: "following", uri: "", name: "Following", pinned: true,
};

export type BlueskySocialCatalog = {
  feeds: SocialFeed[];
  moderation: ModerationOpts;
};

export type BlueskySocialPage = {
  feed: AppBskyFeedDefs.FeedViewPost[];
  cursor?: string;
};

/** OAuth stays bound to the viewer PDS; its AppView proxy supplies viewer state. */
export function createAuthenticatedAppViewAgent(session: OAuthSession): Agent {
  const network = getAtprotoNetwork();
  const agent = network.appLabelers === undefined ? new Agent(session) : new LocalAppViewAgent(session, network.appLabelers);
  return agent.withProxy("bsky_appview", network.appViewDid);
}

function validFeedUri(uri: string, kind: "feed" | "list"): boolean {
  const collection = kind === "feed" ? "app.bsky.feed.generator" : "app.bsky.graph.list";
  return new RegExp(`^at://did:[^/]+/${collection.replaceAll(".", "\\.")}/[^/?#]+$`).test(uri);
}

export function socialFeedHref(feed: SocialFeed): string {
  if (feed.kind === "following") return "/social";
  return `/social?${new URLSearchParams({ [feed.kind]: feed.uri })}`;
}

export function socialFeedFromSearchParams(params: Pick<URLSearchParams, "get">): SocialFeed {
  const feed = params.get("feed");
  const list = params.get("list");
  if (feed && list) throw new Error("Choose one social feed at a time.");
  const kind = feed ? "feed" : list ? "list" : null;
  const uri = feed || list;
  if (!kind || !uri) return SOCIAL_FOLLOWING_FEED;
  if (!validFeedUri(uri, kind)) throw new Error("This social feed link is invalid.");
  return { kind, uri, name: kind === "feed" ? "Saved Feed" : "Saved List", pinned: false };
}

/** Timeline preference entries refer to Following, which is always present once. */
export function socialFeedsFromPreferences(saved: readonly AppBskyActorDefs.SavedFeed[]): SocialFeed[] {
  const seen = new Set<string>();
  const feeds: SocialFeed[] = [];
  for (const item of saved) {
    if (item.type !== "feed" && item.type !== "list") continue;
    const kind = item.type === "feed" ? "feed" : "list";
    if (!validFeedUri(item.value, kind)) continue;
    const key = `${kind}:${item.value}`;
    if (seen.has(key)) continue;
    seen.add(key);
    feeds.push({ kind, uri: item.value, pinned: item.pinned, name: kind === "feed" ? "Saved Feed" : "Saved List" });
  }
  return [SOCIAL_FOLLOWING_FEED, ...feeds.filter(feed => feed.pinned), ...feeds.filter(feed => !feed.pinned)];
}

function throwIfAborted(signal?: AbortSignal): void {
  signal?.throwIfAborted();
}

/** Navigation exposes names only when both content and creator identity are safe. */
function canDisplayCatalogName(decision: ModerationDecision): boolean {
  return (["contentList", "contentView", "profileList", "displayName"] as const).every(context => {
    const ui = decision.ui(context);
    return !ui.filter && !ui.blur && !ui.noOverride;
  });
}

export async function getBlueskySocialCatalog(session: OAuthSession, signal?: AbortSignal): Promise<BlueskySocialCatalog> {
  const agent = createAuthenticatedAppViewAgent(session);
  const preferences = await agent.getPreferences();
  throwIfAborted(signal);
  agent.configureLabelers(preferences.moderationPrefs.labelers.map(labeler => labeler.did));
  // No timeline can render until the viewer's custom safety definitions are ready.
  const requiredLabelers = new Set([...agent.appLabelers, ...preferences.moderationPrefs.labelers.map(labeler => labeler.did)]);
  // getServices requires at least one DID; built-in moderation needs no remote definitions.
  const labelDefs = requiredLabelers.size ? await agent.getLabelDefinitions(preferences) : {};
  throwIfAborted(signal);
  for (const did of requiredLabelers) {
    if (!Object.hasOwn(labelDefs, did)) throw new Error("Your moderation settings could not be loaded. Please retry.");
  }
  const moderation: ModerationOpts = { userDid: session.did, prefs: preferences.moderationPrefs, labelDefs };
  const feeds = socialFeedsFromPreferences(preferences.savedFeeds);
  const generators = feeds.filter(feed => feed.kind === "feed");
  const names = new Map<string, string>();
  // Metadata is optional: deleted/unavailable saved feeds remain navigable entries.
  for (let offset = 0; offset < generators.length; offset += 25) {
    try {
      const result = await agent.app.bsky.feed.getFeedGenerators({ feeds: generators.slice(offset, offset + 25).map(feed => feed.uri) }, { signal });
      for (const feed of result.data.feeds) {
        if (canDisplayCatalogName(moderateFeedGenerator(feed, moderation))) names.set(feed.uri, feed.displayName);
      }
    } catch (error) {
      throwIfAborted(signal);
      if (isMissingOAuthScope(error)) throw error;
    }
  }
  const lists = feeds.filter(feed => feed.kind === "list");
  for (let offset = 0; offset < lists.length; offset += 10) {
    await Promise.all(lists.slice(offset, offset + 10).map(async feed => {
      try {
        const result = await agent.app.bsky.graph.getList({ list: feed.uri, limit: 1 }, { signal });
        if (canDisplayCatalogName(moderateUserList(result.data.list, moderation))) names.set(feed.uri, result.data.list.name);
      } catch (error) {
        throwIfAborted(signal);
        if (isMissingOAuthScope(error)) throw error;
      }
    }));
  }
  throwIfAborted(signal);
  return {
    feeds: feeds.map(feed => ({ ...feed, name: names.get(feed.uri) || feed.name })),
    moderation,
  };
}

export async function getBlueskySocialPage(args: {
  session: OAuthSession;
  feed: SocialFeed;
  moderation: ModerationOpts;
  cursor?: string;
  signal?: AbortSignal;
}): Promise<BlueskySocialPage> {
  if (args.moderation.userDid !== args.session.did) throw new Error("Your account changed. Please reload this feed.");
  if (args.feed.kind !== "following" && !validFeedUri(args.feed.uri, args.feed.kind)) throw new Error("This social feed link is invalid.");
  const agent = createAuthenticatedAppViewAgent(args.session);
  agent.configureLabelers(args.moderation.prefs.labelers.map(labeler => labeler.did));
  const params = { cursor: args.cursor, limit: 30 };
  const options = { signal: args.signal };
  const response = args.feed.kind === "following"
    ? await agent.getTimeline(params, options)
    : args.feed.kind === "feed"
      ? await agent.app.bsky.feed.getFeed({ ...params, feed: args.feed.uri }, options)
      : await agent.app.bsky.feed.getListFeed({ ...params, list: args.feed.uri }, options);
  return response.data;
}

/** Keep repost identity while deduplicating overlaps between paginated results. */
export function socialPostIdentity(item: AppBskyFeedDefs.FeedViewPost): string {
  const reason = item.reason;
  return AppBskyFeedDefs.isReasonRepost(reason)
    ? `${item.post.uri}:repost:${reason.by.did}:${reason.indexedAt}`
    : item.post.uri;
}

export function flattenSocialPages(pages: readonly BlueskySocialPage[]): AppBskyFeedDefs.FeedViewPost[] {
  const seen = new Set<string>();
  return pages.flatMap(page => page.feed).filter(item => {
    const key = socialPostIdentity(item);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function nextSocialCursor(lastPage: BlueskySocialPage, pageParams: readonly unknown[]): string | undefined {
  const cursor = lastPage.cursor;
  return cursor && !pageParams.includes(cursor) ? cursor : undefined;
}

export function socialErrorMessage(error: unknown): string {
  if (isMissingOAuthScope(error) || (error instanceof Error && error.message === SCOPE_RECOVERY_MESSAGE)) return SCOPE_RECOVERY_MESSAGE;
  if (error instanceof Error && /moderation settings|account changed|social feed link|Choose one social feed/.test(error.message)) return error.message;
  return "This social feed could not be loaded. Please retry.";
}
