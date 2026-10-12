"use client";

import { MessageCircle } from "lucide-react";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { DialogTrigger } from "@/components/ui/dialog";
import { formatSocialEngagementCount } from "@/lib/formatSocialEngagementCount";
import { SocialPostComposeDialog } from "./SocialPostComposeDialog";

export function SocialReplyButton({ post, className, moderation }: { post: AppBskyFeedDefs.PostView; className: string; moderation: ModerationOpts }) {
  return <SocialPostComposeDialog post={post} moderation={moderation} mode="reply" trigger={(_openComposer, disabled) =>
    <DialogTrigger className={className} title={post.viewer?.replyDisabled ? "Replies Are Disabled" : `${post.replyCount ?? 0} Replies`} aria-label={`Reply (${post.replyCount ?? 0})`} disabled={disabled}><MessageCircle aria-hidden="true" className="size-4" /><span>{formatSocialEngagementCount(post.replyCount ?? 0)}</span></DialogTrigger>
  } />;
}
