import { AppBskyFeedPost, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent, type BlueskySocialPage } from "@/lib/blueskySocialClient";
import { hydrateSocialReplies } from "./hydrateSocialReplies";

export type ProfileSection = "posts" | "replies" | "media" | "likes";

const AUTHOR_FILTERS = {
  posts: "posts_no_replies",
  replies: "posts_with_replies",
  media: "posts_with_media",
} as const;

/** Viewer-aware profile reads retain PDS OAuth binding and the current moderation subscriptions. */
export async function getBlueskyProfilePage(args: {
  session: OAuthSession;
  tab: ProfileSection;
  actor?: string;
  moderation: ModerationOpts;
  cursor?: string;
  signal?: AbortSignal;
}): Promise<BlueskySocialPage> {
  if (args.moderation.userDid !== args.session.did) throw new Error("Your account changed. Please reload this feed.");
  if (args.tab !== "likes" && !Object.hasOwn(AUTHOR_FILTERS, args.tab)) throw new Error("This profile tab is invalid.");
  const actor = args.actor ?? args.session.did;
  if (args.tab === "likes" && actor !== args.session.did) throw new Error("Likes are private. Only your own likes are available.");
  const agent = createAuthenticatedAppViewAgent(args.session);
  agent.configureLabelers(args.moderation.prefs.labelers.map(labeler => labeler.did));
  const params = { actor, limit: 30, cursor: args.cursor };
  const options = { signal: args.signal };
  const response = args.tab === "likes"
    ? await agent.app.bsky.feed.getActorLikes(params, options)
    : await agent.app.bsky.feed.getAuthorFeed({ ...params, filter: AUTHOR_FILTERS[args.tab] }, options);
  const feed = args.tab === "replies"
    ? response.data.feed.filter(item => AppBskyFeedPost.isRecord(item.post.record) && !!item.post.record.reply)
    : response.data.feed;
  return { ...response.data, feed: await hydrateSocialReplies(agent, feed, args.signal) };
}
