import {
  AppBskyEmbedRecord,
  AppBskyEmbedRecordWithMedia,
  AppBskyFeedDefs,
  moderateProfile,
  type ModerationOpts,
} from "@atproto/api";
import { moderateSocialPost } from "@/components/Social/socialModeration";

/** Hide the enclosing interaction whenever its known source is withheld. */
export function isSocialInteractionHidden(item: AppBskyFeedDefs.FeedViewPost, options: ModerationOpts): boolean {
  const withheld = (ui: { filter: boolean; blur: boolean; noOverride: boolean }) => ui.filter || ui.blur || ui.noOverride;
  const seen = new Set<string>();
  const hiddenPost = (post: AppBskyFeedDefs.PostView): boolean => {
    if (seen.has(post.uri)) return false;
    seen.add(post.uri);
    const profile = moderateProfile(post.author, options);
    return withheld(moderateSocialPost(post, options).ui("contentList")) ||
      withheld(profile.ui("profileList")) || withheld(profile.ui("displayName")) || hiddenQuote(post);
  };
  const hiddenQuote = (post: AppBskyFeedDefs.PostView): boolean => {
    const embed = post.embed;
    const value = AppBskyEmbedRecord.isView(embed) ? embed.record
      : AppBskyEmbedRecordWithMedia.isView(embed) ? embed.record.record : undefined;
    if (AppBskyEmbedRecord.isViewBlocked(value)) return true;
    const quote = AppBskyEmbedRecord.validateViewRecord(value);
    if (!quote.success) return false;
    return hiddenPost({ uri: quote.value.uri, cid: quote.value.cid,
      author: quote.value.author, record: quote.value.value,
      indexedAt: quote.value.indexedAt, labels: quote.value.labels, embed: quote.value.embeds?.[0] });
  };
  const hiddenParent = (view: NonNullable<AppBskyFeedDefs.FeedViewPost["reply"]>["parent"] | undefined) =>
    AppBskyFeedDefs.isBlockedPost(view) || (AppBskyFeedDefs.isPostView(view) && hiddenPost(view));
  if (hiddenParent(item.reply?.parent) || hiddenParent(item.reply?.root)) return true;
  if (AppBskyFeedDefs.isReasonRepost(item.reason)) {
    const reposter = moderateProfile(item.reason.by, options);
    if (withheld(reposter.ui("profileList")) || withheld(reposter.ui("displayName")) || hiddenPost(item.post)) return true;
  }
  return hiddenQuote(item.post);
}
