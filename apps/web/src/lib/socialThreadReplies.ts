import { AppBskyFeedDefs } from "@atproto/api";

export interface SocialThreadReply {
  post: AppBskyFeedDefs.PostView;
  parent: AppBskyFeedDefs.PostView;
  /** Direct replies start at zero; deeper branches open as focused conversations. */
  depth: number;
  hasMore: boolean;
}

export function collectSocialThreadReplies(
  root: AppBskyFeedDefs.ThreadViewPost | undefined,
  excludedUris: Iterable<string> = [],
): SocialThreadReply[] {
  if (!root) return [];
  const rows: SocialThreadReply[] = [];
  const seen = new Set([root.post.uri, ...excludedUris]);
  const pending = (root.replies ?? []).map(node => ({ node, parent: root.post, depth: 0 })).reverse();
  // Preserve API order while keeping each visible branch within the indent limit.
  while (pending.length && rows.length < 100) {
    const { node, parent, depth } = pending.pop()!;
    if (!AppBskyFeedDefs.isThreadViewPost(node) || seen.has(node.post.uri)) continue;
    seen.add(node.post.uri);
    const hasMore = depth === 3 && (node.replies ? node.replies.length > 0 : (node.post.replyCount ?? 0) > 0);
    rows.push({ post: node.post, parent, depth, hasMore });
    if (depth === 3) continue;
    for (const child of (node.replies ?? []).toReversed()) {
      pending.push({ node: child, parent: node.post, depth: depth + 1 });
    }
  }
  return rows;
}

export function socialThreadReplyIndent(depth: number): string {
  if (depth <= 0) return "";
  if (depth === 1) return "ml-3 sm:ml-5";
  if (depth === 2) return "ml-6 sm:ml-10";
  return "ml-9 sm:ml-15";
}
