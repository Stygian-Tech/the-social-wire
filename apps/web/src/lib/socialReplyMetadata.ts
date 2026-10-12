import { AppBskyFeedPost, type AppBskyFeedDefs } from "@atproto/api";

/** Record references identify replies even when AppView omits feed context. */
export function socialReplyMetadata(item: AppBskyFeedDefs.FeedViewPost, posts: ReadonlyMap<string, AppBskyFeedDefs.PostView> = new Map()): AppBskyFeedDefs.FeedViewPost["reply"] {
  if (item.reply) return item.reply;
  const record = AppBskyFeedPost.validateRecord(item.post.record);
  const refs = record.success ? record.value.reply : undefined;
  if (!refs || refs.parent.uri === item.post.uri) return undefined;
  const view = (uri: string) => {
    const post = posts.get(uri);
    return post ? { ...post, $type: "app.bsky.feed.defs#postView" as const } : { uri, $type: "app.bsky.feed.defs#notFoundPost" as const, notFound: true };
  };
  return { parent: view(refs.parent.uri), root: view(refs.root.uri) };
}
