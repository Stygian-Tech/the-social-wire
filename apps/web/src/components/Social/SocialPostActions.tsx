"use client";

import { Bookmark, Heart, MessageCircle, Repeat2 } from "lucide-react";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { useBlueskyBookmark } from "@/hooks/useBlueskyBookmarks";
import { useBlueskyPostEngagement } from "@/hooks/useBlueskyPostEngagement";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SocialPostMenu } from "./SocialPostMenu";

export function SocialPostActions({ post, moderation, onOpen }: { post: AppBskyFeedDefs.PostView; moderation: ModerationOpts; onOpen: () => void }) {
  const { engagement, toggleLike, toggleRepost, isPending, error } = useBlueskyPostEngagement(post, moderation);
  const bookmark = useBlueskyBookmark(post, moderation);
  const button = "inline-flex min-h-8 min-w-8 items-center justify-center gap-2 rounded-lg px-1 transition-colors hover:bg-accent focus-visible:outline-2 focus-visible:outline-primary disabled:opacity-50";
  return <div>
    <div className="flex items-start justify-between gap-6 text-sm text-muted-foreground" aria-label="Post Actions">
      <div className="flex items-center gap-2 sm:gap-6">
      <button className={button} aria-label={`Open Replies (${post.replyCount ?? 0})`} onClick={onOpen}><MessageCircle className="size-4" /><span>{post.replyCount ?? 0}</span></button>
      <button className={`${button} ${engagement.repost ? "text-green-600 dark:text-green-400" : ""}`} aria-label={`Repost (${engagement.repostCount})`} aria-pressed={!!engagement.repost} disabled={isPending} onClick={toggleRepost}><Repeat2 className="size-4" /><span>{engagement.repostCount}</span></button>
      <button className={`${button} ${engagement.like ? "text-rose-600 dark:text-rose-400" : ""}`} aria-label={`Like (${engagement.likeCount})`} aria-pressed={!!engagement.like} disabled={isPending} onClick={toggleLike}><Heart className={`size-4 ${engagement.like ? "fill-current" : ""}`} /><span>{engagement.likeCount}</span></button>
      </div>
      <div className="grid grid-cols-2 items-center gap-2">
      <button className={`${button} ${bookmark.saved ? "text-primary" : ""}`} aria-label={bookmark.saved ? "Remove Bookmark" : "Bookmark Post"} aria-pressed={bookmark.saved} disabled={bookmark.isPending} onClick={bookmark.toggle}><Bookmark className={`size-4 ${bookmark.saved ? "fill-current" : ""}`} /></button>
      <SocialPostMenu uri={post.uri} className={button} />
      </div>
    </div>
    {error ? <p role="alert" className="mt-2 text-xs text-destructive">{socialErrorMessage(error)}</p> : null}
    {error && socialErrorMessage(error) === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
    {bookmark.error ? <p role="alert" className="mt-2 text-xs text-destructive">{socialErrorMessage(bookmark.error)}</p> : null}
    {bookmark.error && socialErrorMessage(bookmark.error) === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
  </div>;
}
