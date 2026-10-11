"use client";

import { AppBskyFeedPost, AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import { SocialPostCard } from "./SocialPostCard";
import { SocialPostActions } from "./SocialPostActions";
import { useSocialPostNavigation } from "@/hooks/useSocialPostNavigation";
import { SocialReplyContext } from "./SocialReplyContext";
import { moderateSocialPost } from "./socialModeration";

export function InteractiveSocialPost({ item, moderation, showReplyParentActions = false }: { item: AppBskyFeedDefs.FeedViewPost; moderation: ModerationOpts; showReplyParentActions?: boolean }) {
  const navigation = useSocialPostNavigation();
  const content = moderateSocialPost(item.post, moderation).ui("contentList");
  const showContext = !content.filter && !content.blur && !content.noOverride && AppBskyFeedPost.validateRecord(item.post.record).success;
  const grouped = showContext && !!item.reply && !(AppBskyFeedDefs.isPostView(item.reply.parent) && item.reply.parent.uri === item.post.uri);
  const parent = item.reply && AppBskyFeedDefs.isPostView(item.reply.parent) ? item.reply.parent : undefined;
  const openPost = (post: AppBskyFeedDefs.PostView) => navigation.openPost(post.uri);
  return <div aria-label={grouped ? "Post Conversation" : undefined} className={`flex min-w-0 shrink-0 flex-col gap-3 ${grouped ? "rounded-2xl border bg-card p-4 text-card-foreground" : ""}`}>
    {grouped && item.reply ? <SocialReplyContext reply={item.reply} postUri={item.post.uri} moderation={moderation} onOpenPost={openPost} parentActions={showReplyParentActions && parent ? <SocialPostActions post={parent} moderation={moderation} onOpen={() => openPost(parent)} /> : undefined} /> : null}
    <SocialPostCard embedded={grouped} item={item} moderation={moderation} onOpen={() => openPost(item.post)} onOpenPost={openPost} actions={<SocialPostActions post={item.post} moderation={moderation} onOpen={() => openPost(item.post)} />} />
  </div>;
}
