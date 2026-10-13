import { type Agent, type AppBskyFeedDefs } from "@atproto/api";
import { isMissingOAuthScope, SCOPE_RECOVERY_MESSAGE } from "./oauthScopeRecovery";
import { socialReplyMetadata } from "./socialReplyMetadata";
import { isPendingSocialReplyPost } from "./pendingSocialReplyPost";

/** Fill only omitted context, preserving upstream blocked/deleted parent states. */
export async function hydrateSocialReplies(agent: Agent, items: readonly AppBskyFeedDefs.FeedViewPost[], signal?: AbortSignal): Promise<AppBskyFeedDefs.FeedViewPost[]> {
  signal?.throwIfAborted();
  const posts = new Map(items.map(item => [item.post.uri, item.post]));
  const unavailablePosts = new Set<string>();
  const uris = [...new Set(items.flatMap(item => {
    const reply = socialReplyMetadata(item, posts);
    return reply ? [reply.parent, reply.root].filter(isPendingSocialReplyPost).map(view => view.uri) : [];
  }))];
  for (let offset = 0; offset < uris.length; offset += 25) {
    const requested = uris.slice(offset, offset + 25);
    try {
      const result = await agent.app.bsky.feed.getPosts({ uris: requested }, { signal });
      signal?.throwIfAborted();
      for (const post of result.data.posts) if (requested.includes(post.uri)) posts.set(post.uri, post);
      for (const uri of requested) if (!posts.has(uri)) unavailablePosts.add(uri);
    } catch (error) {
      signal?.throwIfAborted();
      if (isMissingOAuthScope(error) || (error instanceof Error && error.message === SCOPE_RECOVERY_MESSAGE)) throw error;
      // Optional context must not prevent the reply itself from rendering.
    }
  }
  return items.map(item => {
    const reply = socialReplyMetadata(item, posts, unavailablePosts);
    return reply && reply !== item.reply ? { ...item, reply } : item;
  });
}
