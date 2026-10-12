"use client";

import { Quote, Repeat2 } from "lucide-react";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { DropdownMenu, DropdownMenuContent, DropdownMenuGroup, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { formatSocialEngagementCount } from "@/lib/formatSocialEngagementCount";
import { SocialPostComposeDialog } from "./SocialPostComposeDialog";

export function SocialRepostButton({ post, moderation, className, reposted, repostCount, pending, onRepost }: {
  post: AppBskyFeedDefs.PostView;
  moderation: ModerationOpts;
  className: string;
  reposted: boolean;
  repostCount: number;
  pending: boolean;
  onRepost: () => void;
}) {
  const { session } = useAuth();
  return <SocialPostComposeDialog post={post} moderation={moderation} mode="quote" trigger={(openComposer, quoteDisabled) =>
    <DropdownMenu>
      <DropdownMenuTrigger className={className} title={`${repostCount} Reposts`} aria-label={`Repost (${repostCount})`} disabled={pending || !session || moderation.userDid !== session.did}>
        <Repeat2 aria-hidden="true" className="size-4" /><span>{formatSocialEngagementCount(repostCount)}</span>
        {reposted ? <span className="sr-only">Reposted</span> : null}
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="min-w-40" onClick={event => event.stopPropagation()}>
        <DropdownMenuGroup>
          <DropdownMenuItem disabled={pending} onClick={onRepost}><Repeat2 aria-hidden="true" />{reposted ? "Undo Repost" : "Repost"}</DropdownMenuItem>
          <DropdownMenuItem disabled={pending || quoteDisabled} onClick={openComposer}><Quote aria-hidden="true" />Quote Post</DropdownMenuItem>
        </DropdownMenuGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  } />;
}
