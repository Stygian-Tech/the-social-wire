import { AppBskyFeedDefs, AppBskyFeedPost, type ModerationOpts } from "@atproto/api";
import { moderateSocialPost } from "@/components/Social/socialModeration";

/** Count connected OP self-replies, never replies through another author. */
export function socialAuthorThread(thread: unknown, moderation: ModerationOpts): { count: number; partial: boolean } | undefined {
  if (!AppBskyFeedDefs.isThreadViewPost(thread)) return undefined;
  const root = thread as AppBskyFeedDefs.ThreadViewPost;
  const rootRecord = AppBskyFeedPost.validateRecord(root.post.record);
  if (!rootRecord.success || rootRecord.value.reply) return undefined;
  const author = root.post.author.did;
  const seen = new Set<string>();
  let count = 0;
  let partial = false;
  function visit(node: AppBskyFeedDefs.ThreadViewPost, parentUri?: string) {
    if (node.post.author.did !== author) return;
    const record = AppBskyFeedPost.validateRecord(node.post.record);
    if (!record.success) { partial = true; return; }
    if (parentUri && record.value.reply?.parent.uri !== parentUri) return;
    const content = moderateSocialPost(node.post, moderation).ui("contentList");
    if (content.filter || content.blur || content.noOverride) { partial = true; return; }
    if (seen.has(node.post.uri) || count >= 100) { partial = true; return; }
    seen.add(node.post.uri);
    count++;
    const replies = node.replies ?? [];
    if ((node.post.replyCount ?? 0) > replies.length) partial = true;
    for (const reply of replies) {
      if (AppBskyFeedDefs.isThreadViewPost(reply)) visit(reply, node.post.uri);
      else partial = true;
    }
  }
  visit(root);
  return count ? { count, partial } : undefined;
}

export function socialAuthorThreadUri(item: AppBskyFeedDefs.FeedViewPost): string | undefined {
  if (!item.reply) {
    const record = AppBskyFeedPost.validateRecord(item.post.record);
    return record.success && !record.value.reply && (item.post.replyCount ?? 0) > 0 ? item.post.uri : undefined;
  }
  const { parent, root } = item.reply;
  return AppBskyFeedDefs.isPostView(parent) && AppBskyFeedDefs.isPostView(root) && parent.author.did === item.post.author.did && root.author.did === item.post.author.did ? root.uri : undefined;
}

/** Parent responses omit replies; stitch the known self-reply path without claiming completeness. */
export function socialAuthorThreadRoot(thread: AppBskyFeedDefs.ThreadViewPost): AppBskyFeedDefs.ThreadViewPost {
  let current = thread;
  const seen = new Set([current.post.uri]);
  while (AppBskyFeedDefs.isThreadViewPost(current.parent) && !seen.has(current.parent.post.uri)) {
    const parent = current.parent;
    const record = AppBskyFeedPost.validateRecord(current.post.record);
    if (parent.post.author.did !== thread.post.author.did || !record.success || record.value.reply?.parent.uri !== parent.post.uri) break;
    seen.add(parent.post.uri);
    current = { ...parent, replies: [...(parent.replies ?? []).filter(node => !AppBskyFeedDefs.isThreadViewPost(node) || node.post.uri !== current.post.uri), { ...current, $type: "app.bsky.feed.defs#threadViewPost" }] };
  }
  return current;
}
