"use client";

import { useState } from "react";
import { AppBskyFeedPost, type AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import { SocialPostCard } from "./SocialPostCard";
import { SocialPostActions } from "./SocialPostActions";
import { SocialPostDialog } from "./SocialPostDialog";
import { SocialReplyContext } from "./SocialReplyContext";
import { moderateSocialPost } from "./socialModeration";

export function InteractiveSocialPost({ item, moderation }: { item: AppBskyFeedDefs.FeedViewPost; moderation: ModerationOpts }) {
  const [selected, setSelected] = useState<AppBskyFeedDefs.FeedViewPost>();
  const content = moderateSocialPost(item.post, moderation).ui("contentList");
  const showContext = !content.filter && !content.blur && !content.noOverride && AppBskyFeedPost.validateRecord(item.post.record).success;
  const openPost = (post: AppBskyFeedDefs.PostView) => setSelected(post.uri === item.post.uri ? item : { post });
  return <div className="flex min-w-0 shrink-0 flex-col gap-2">
    {showContext && item.reply ? <SocialReplyContext reply={item.reply} postUri={item.post.uri} moderation={moderation} onOpenPost={openPost} /> : null}
    <SocialPostCard item={item} moderation={moderation} onOpen={() => setSelected(item)} onOpenPost={openPost} actions={<SocialPostActions post={item.post} moderation={moderation} onOpen={() => setSelected(item)} />} />
    {selected ? <SocialPostDialog key={moderation.userDid} item={selected} moderation={moderation} open onOpenChange={open => { if (!open) setSelected(undefined); }} /> : null}
  </div>;
}
