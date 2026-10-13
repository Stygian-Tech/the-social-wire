import { AppBskyFeedPost, AppBskyFeedDefs } from "@atproto/api";
import { isPendingSocialReplyPost, PENDING_SOCIAL_REPLY_POST } from "./pendingSocialReplyPost";

/** Record references identify replies even when AppView omits feed context. */
export function socialReplyMetadata(item: AppBskyFeedDefs.FeedViewPost, posts: ReadonlyMap<string, AppBskyFeedDefs.PostView> = new Map(), unavailablePosts: ReadonlySet<string> = new Set()): AppBskyFeedDefs.FeedViewPost["reply"] {
  const view = (uri: string) => {
    const post = posts.get(uri);
    return post ? { ...post, $type: "app.bsky.feed.defs#postView" as const }
      : unavailablePosts.has(uri) ? { uri, $type: "app.bsky.feed.defs#notFoundPost" as const, notFound: true }
      : { uri, $type: PENDING_SOCIAL_REPLY_POST };
  };
  if (item.reply) {
    const resolve = (view: typeof item.reply.parent) => {
      const post = AppBskyFeedDefs.isNotFoundPost(view) || isPendingSocialReplyPost(view) ? posts.get(view.uri) : undefined;
      if (AppBskyFeedDefs.isNotFoundPost(view) && view.notFound !== true && !post) {
        return { uri: view.uri, $type: PENDING_SOCIAL_REPLY_POST };
      }
      if (isPendingSocialReplyPost(view) && unavailablePosts.has(view.uri) && !post) {
        return { uri: view.uri, $type: "app.bsky.feed.defs#notFoundPost" as const, notFound: true };
      }
      return post ? { ...post, $type: "app.bsky.feed.defs#postView" as const } : view;
    };
    const parent = resolve(item.reply.parent);
    const root = resolve(item.reply.root);
    return parent === item.reply.parent && root === item.reply.root
      ? item.reply : { ...item.reply, parent, root };
  }
  const record = AppBskyFeedPost.validateRecord(item.post.record);
  const refs = record.success ? record.value.reply : undefined;
  if (!refs || refs.parent.uri === item.post.uri) return undefined;
  return { parent: view(refs.parent.uri), root: view(refs.root.uri) };
}
