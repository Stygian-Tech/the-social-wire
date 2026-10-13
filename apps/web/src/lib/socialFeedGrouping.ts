import { AppBskyFeedDefs, AppBskyFeedPost, type ModerationOpts } from "@atproto/api";
import { moderateSocialPost } from "@/components/Social/socialModeration";
import { socialReplyMetadata } from "./socialReplyMetadata";
import { isSocialInteractionHidden } from "./socialInteractionModeration";

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
  const posts = new Map(items.map(item => [item.post.uri, item.post]));
  const addContextPost = (view: NonNullable<AppBskyFeedDefs.FeedViewPost["reply"]>["parent"] | undefined) => {
    if (AppBskyFeedDefs.isPostView(view) && !posts.has(view.uri)) posts.set(view.uri, view);
  };
  for (const item of items) {
    addContextPost(item.reply?.parent);
    addContextPost(item.reply?.root);
  }
  const resolved = items.map(item => {
    const reply = socialReplyMetadata(item, posts);
    return reply === item.reply ? item : { ...item, reply };
  });
  const visible = resolved.filter(item => !isSocialInteractionHidden(item, moderation));
  const contextualParents = new Set(visible.map(item => displayedSocialReplyParent(item, moderation)?.uri).filter(Boolean));
  return visible.filter(item => item.reply || item.reason || !contextualParents.has(item.post.uri));
}
