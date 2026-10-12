"use client";

import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { groupSocialFeedItems } from "@/lib/socialFeedGrouping";
import { socialPostIdentity } from "@/lib/blueskySocialClient";
import { InteractiveSocialPost } from "./InteractiveSocialPost";

export function SocialFeedPosts({ items, moderation }: { items: readonly AppBskyFeedDefs.FeedViewPost[]; moderation: ModerationOpts }) {
  return groupSocialFeedItems(items, moderation).map(item => <InteractiveSocialPost key={`${moderation.userDid}:${socialPostIdentity(item)}`} item={item} moderation={moderation} />);
}
