import {
  AppBskyFeedPost,
  moderatePost,
  type AppBskyFeedDefs,
  type ModerationOpts,
} from "@atproto/api";

/** Invalid post records still receive author, label, and hidden-post filtering. */
export function moderateSocialPost(
  post: AppBskyFeedDefs.PostView,
  options: ModerationOpts,
) {
  const record = AppBskyFeedPost.validateRecord(post.record);
  return moderatePost(
    record.success
      ? post
      : {
          ...post,
          record: {
            $type: "app.bsky.feed.post",
            text: "",
            createdAt: post.indexedAt,
          },
        },
    options,
  );
}
