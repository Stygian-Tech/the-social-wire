import { AppBskyFeedDefs, AppBskyFeedPost, type ModerationOpts } from "@atproto/api";
import { moderateSocialPost } from "@/components/Social/socialModeration";

/** Only full, visible parent content can replace a standalone feed row. */
export function displayedSocialReplyParent(item: AppBskyFeedDefs.FeedViewPost, moderation: ModerationOpts): AppBskyFeedDefs.PostView | undefined {
  const parent = item.reply?.parent;
  if (!AppBskyFeedDefs.isPostView(parent) || parent.uri === item.post.uri) return undefined;
  for (const post of [item.post, parent]) {
    if (!AppBskyFeedPost.validateRecord(post.record).success) return undefined;
    const content = moderateSocialPost(post, moderation).ui("contentList");
    if (content.filter || content.blur || content.noOverride) return undefined;
  }
  return parent;
}

/** Preserve source ordering and all reply/repost attribution across loaded pages. */
export function groupSocialFeedItems(items: readonly AppBskyFeedDefs.FeedViewPost[], moderation: ModerationOpts): AppBskyFeedDefs.FeedViewPost[] {
  const contextualParents = new Set(items.map(item => displayedSocialReplyParent(item, moderation)?.uri).filter(Boolean));
  return items.filter(item => item.reply || item.reason || !contextualParents.has(item.post.uri));
}
