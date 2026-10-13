import { AppBskyFeedPost, AppBskyFeedDefs } from "@atproto/api";

/** Record references identify replies even when AppView omits feed context. */
export function socialReplyMetadata(item: AppBskyFeedDefs.FeedViewPost, posts: ReadonlyMap<string, AppBskyFeedDefs.PostView> = new Map()): AppBskyFeedDefs.FeedViewPost["reply"] {
  if (item.reply) {
    const resolve = (view: typeof item.reply.parent) => {
      const post = AppBskyFeedDefs.isNotFoundPost(view) ? posts.get(view.uri) : undefined;
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
  const view = (uri: string) => {
    const post = posts.get(uri);
    return post ? { ...post, $type: "app.bsky.feed.defs#postView" as const } : { uri, $type: "app.bsky.feed.defs#notFoundPost" as const, notFound: true };
  };
  return { parent: view(refs.parent.uri), root: view(refs.root.uri) };
}
