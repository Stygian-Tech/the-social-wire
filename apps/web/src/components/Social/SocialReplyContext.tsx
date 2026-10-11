"use client";

import type { ReactNode } from "react";
import { AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import { moderateSocialPost } from "./socialModeration";
import { SocialPostCard } from "./SocialPostCard";

export function SocialReplyContext({ reply, postUri, moderation, onOpenPost, parentActions }: {
  reply: NonNullable<AppBskyFeedDefs.FeedViewPost["reply"]>;
  postUri: string;
  moderation: ModerationOpts;
  onOpenPost: (post: AppBskyFeedDefs.PostView) => void;
  parentActions?: ReactNode;
}) {
  const parent = reply.parent;
  if (AppBskyFeedDefs.isPostView(parent) && parent.uri === postUri) return null;
  const content = AppBskyFeedDefs.isPostView(parent) ? moderateSocialPost(parent, moderation).ui("contentList") : undefined;
  const withheld = content && (content.filter || content.blur || content.noOverride);
  return <section aria-label="Replying To" className="flex min-w-0 flex-col gap-2 border-b border-border pb-3">
    <p className="text-xs text-muted-foreground">Replying To</p>
    {withheld ? <p className="text-sm text-muted-foreground">Original post withheld by your moderation settings.</p> : AppBskyFeedDefs.isPostView(parent) ? <SocialPostCard embedded item={{ post: parent }} actions={parentActions} moderation={moderation} onOpen={() => onOpenPost(parent)} onOpenPost={onOpenPost} /> : <p className="text-sm text-muted-foreground">Original post unavailable.</p>}
  </section>;
}
