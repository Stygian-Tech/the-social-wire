"use client";

import { AppBskyFeedPost, AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import { MessagesSquare } from "lucide-react";
import { SocialAuthorThreadIndicator } from "./SocialAuthorThreadIndicator";
import { SocialPostCard } from "./SocialPostCard";
import { SocialPostActions } from "./SocialPostActions";
import { useSocialPostNavigation } from "@/hooks/useSocialPostNavigation";
import { SocialReplyContext } from "./SocialReplyContext";
import { moderateSocialPost } from "./socialModeration";
import { socialReplyMetadata } from "@/lib/socialReplyMetadata";
import { isSocialInteractionHidden } from "@/lib/socialInteractionModeration";

export function InteractiveSocialPost({ item, moderation, showReplyParentActions = true }: { item: AppBskyFeedDefs.FeedViewPost; moderation: ModerationOpts; showReplyParentActions?: boolean }) {
  const resolvedItem = { ...item, reply: socialReplyMetadata(item) };
  const navigation = useSocialPostNavigation();
  if (isSocialInteractionHidden(resolvedItem, moderation)) return null;
  const content = moderateSocialPost(item.post, moderation).ui("contentList");
  const showContext = !content.filter && !content.blur && !content.noOverride && AppBskyFeedPost.validateRecord(item.post.record).success;
  const grouped = showContext && !!resolvedItem.reply && !(AppBskyFeedDefs.isPostView(resolvedItem.reply.parent) && resolvedItem.reply.parent.uri === item.post.uri);
  const parent = resolvedItem.reply && AppBskyFeedDefs.isPostView(resolvedItem.reply.parent) ? resolvedItem.reply.parent : undefined;
  const root = resolvedItem.reply?.root;
  const threadUri = root && "uri" in root && typeof root.uri === "string" ? root.uri : item.post.uri;
  const openPost = (post: AppBskyFeedDefs.PostView) => navigation.openPost(post.uri);
  return <div aria-label={grouped ? "Post Conversation" : undefined} className={`relative flex min-w-0 shrink-0 flex-col gap-3 ${grouped ? "rounded-2xl border bg-card p-4 text-card-foreground" : ""}`}>
    {grouped ? <p className="flex items-center gap-1.5 text-xs font-medium text-muted-foreground">
      <MessagesSquare aria-hidden="true" className="size-3.5" />
      <span>Conversation</span>
    </p> : null}
    {showContext ? <SocialAuthorThreadIndicator item={resolvedItem} moderation={moderation} onOpen={navigation.openPost} /> : null}
    {grouped && resolvedItem.reply ? <SocialReplyContext reply={resolvedItem.reply} postUri={item.post.uri} moderation={moderation} onOpenPost={openPost} onShowThread={() => navigation.openPost(threadUri)} parentActions={showReplyParentActions && parent ? <SocialPostActions post={parent} moderation={moderation} /> : undefined} /> : null}
    <SocialPostCard embedded={grouped} item={resolvedItem} moderation={moderation} onOpen={() => openPost(item.post)} onOpenPost={openPost} actions={<SocialPostActions post={item.post} moderation={moderation} />} />
  </div>;
}
