import { AppBskyFeedDefs } from "@atproto/api";

export interface SocialThreadReply {
  post: AppBskyFeedDefs.PostView;
  parent: AppBskyFeedDefs.PostView;
  /** Direct replies start at zero; visual indentation can be capped separately. */
  depth: number;
}

export function collectSocialThreadReplies(
  root: AppBskyFeedDefs.ThreadViewPost | undefined,
  excludedUris: Iterable<string> = [],
): SocialThreadReply[] {
  if (!root) return [];
  const rows: SocialThreadReply[] = [];
  const seen = new Set([root.post.uri, ...excludedUris]);
  const pending = (root.replies ?? []).map(node => ({ node, parent: root.post, depth: 0 })).reverse();
  // An explicit stack preserves API order without limiting logical thread depth.
  while (pending.length && rows.length < 100) {
    const { node, parent, depth } = pending.pop()!;
    if (!AppBskyFeedDefs.isThreadViewPost(node) || seen.has(node.post.uri)) continue;
    seen.add(node.post.uri);
    rows.push({ post: node.post, parent, depth });
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
