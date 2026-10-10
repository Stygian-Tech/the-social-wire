"use client";

import { AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { useBlueskyPostThread } from "@/hooks/useBlueskyPostThread";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SocialPostCard } from "./SocialPostCard";
import { SocialPostActions } from "./SocialPostActions";

export function SocialPostDialog({ item, moderation, open, onOpenChange }: { item: AppBskyFeedDefs.FeedViewPost; moderation: ModerationOpts; open: boolean; onOpenChange: (open: boolean) => void }) {
  const query = useBlueskyPostThread(open ? item.post.uri : undefined, moderation);
  const thread = query.data?.thread;
  const root = AppBskyFeedDefs.isThreadViewPost(thread) ? thread : undefined;
  const parents: AppBskyFeedDefs.PostView[] = [];
  let parent = root?.parent;
  while (AppBskyFeedDefs.isThreadViewPost(parent) && parents.length < 80) { parents.unshift(parent.post); parent = parent.parent; }
  const replies: AppBskyFeedDefs.PostView[] = [];
  function collect(nodes: AppBskyFeedDefs.ThreadViewPost["replies"], depth = 0) {
    if (depth > 6 || replies.length >= 100) return;
    for (const node of nodes ?? []) if (AppBskyFeedDefs.isThreadViewPost(node)) {
      if (replies.length >= 100) break;
      replies.push(node.post); collect(node.replies, depth + 1);
    }
  }
  collect(root?.replies);
  const post = root?.post ?? item.post;
  return <Dialog open={open} onOpenChange={onOpenChange}>
    <DialogContent className="flex max-h-[90dvh] flex-col overflow-hidden sm:max-w-2xl">
      <DialogTitle>Post</DialogTitle>
      <DialogDescription className="sr-only">Post content and conversation.</DialogDescription>
      <div className="min-h-0 space-y-3 overflow-y-auto overscroll-contain">
        {parents.map(parentPost => <SocialPostCard key={parentPost.uri} item={{ post: parentPost }} moderation={moderation} />)}
        <SocialPostCard item={{ ...item, post }} moderation={moderation} detailedTimestamp actions={<SocialPostActions post={post} moderation={moderation} onOpen={() => document.getElementById(`replies-${post.uri}`)?.scrollIntoView({ block: "nearest" })} />} />
        <div id={`replies-${post.uri}`} className="space-y-3">
          <h3 className="font-medium">Replies</h3>
          {query.isPending ? <p role="status" className="text-muted-foreground">Loading Conversation…</p> : query.isError ? <p role="alert" className="text-destructive">{socialErrorMessage(query.error)}</p> : !root ? <p className="text-muted-foreground">This conversation is unavailable.</p> : replies.length === 0 ? <p className="text-muted-foreground">No replies yet.</p> : null}
          {query.isError && socialErrorMessage(query.error) === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
          {replies.map(reply => <SocialPostCard key={reply.uri} item={{ post: reply }} moderation={moderation} />)}
        </div>
      </div>
    </DialogContent>
  </Dialog>;
}
