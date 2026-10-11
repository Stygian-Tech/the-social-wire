"use client";

import { useSearchParams } from "next/navigation";
import { useEffect, useRef } from "react";
import { AppBskyFeedDefs, AppBskyFeedPost } from "@atproto/api";
import { ArrowLeft } from "lucide-react";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useBlueskyPostThread } from "@/hooks/useBlueskyPostThread";
import { useSocialPostNavigation } from "@/hooks/useSocialPostNavigation";
import { useSocialThreadNavigation } from "@/hooks/useSocialThreadNavigation";
import { isSocialPostUri } from "@/lib/socialPostNavigation";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { collectSocialThreadReplies, socialThreadReplyIndent } from "@/lib/socialThreadReplies";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialPostCard } from "./SocialPostCard";
import { SocialAuthorThreadIndicator } from "./SocialAuthorThreadIndicator";
import { socialAuthorThreadRoot } from "@/lib/socialAuthorThread";
import { SocialPostActions } from "./SocialPostActions";
import { moderateSocialPost } from "./socialModeration";

export function SocialPostPage() {
  const { session } = useAuth();
  const params = useSearchParams();
  const uri = params?.get("uri");
  return <SocialPostViewer key={`${session?.did ?? ""}:${uri}`} uri={uri} />;
}

function SocialPostViewer({ uri }: { uri: string | null | undefined }) {
  const { session } = useAuth();
  const navigation = useSocialPostNavigation();
  const threadNavigation = useSocialThreadNavigation();
  const restoreThread = threadNavigation.restore;
  const scrollContainer = useRef<HTMLDivElement>(null);
  const restored = useRef(false);
  const catalog = useBlueskySocialCatalog();
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === session?.did ? catalog.data?.moderation : undefined;
  const valid = isSocialPostUri(uri);
  const query = useBlueskyPostThread(valid ? uri : undefined, moderation);
  const thread = !query.isError && moderation ? query.data?.thread : undefined;
  const root: AppBskyFeedDefs.ThreadViewPost | undefined = AppBskyFeedDefs.isThreadViewPost(thread) ? thread as AppBskyFeedDefs.ThreadViewPost : undefined;
  useEffect(() => {
    if (!root || restored.current) return;
    restored.current = restoreThread(scrollContainer.current);
  }, [root, restoreThread]);
  const parents: AppBskyFeedDefs.PostView[] = [];
  const seen = new Set(root ? [root.post.uri] : []);
  let parent = root?.parent;
  while (AppBskyFeedDefs.isThreadViewPost(parent) && parents.length < 80 && !seen.has(parent.post.uri)) {
    seen.add(parent.post.uri); parents.unshift(parent.post); parent = parent.parent;
  }
  const replies = collectSocialThreadReplies(root, seen);
  const error = catalog.isError ? socialErrorMessage(catalog.error) : query.isError ? socialErrorMessage(query.error) : undefined;
  const openPost = (post: AppBskyFeedDefs.PostView) => navigation.openPost(post.uri);
  return <div className="flex min-h-0 w-full flex-1 flex-col">
    <FeedHeader title="Post" subtitle="Conversation" leading={<Button variant="ghost" size="icon" aria-label="Back" title="Back" className="min-h-11 min-w-11" onClick={threadNavigation.back}><ArrowLeft aria-hidden="true" /></Button>} />
    <div ref={scrollContainer} className="min-h-0 flex-1 overflow-y-auto overscroll-contain"><section aria-label="Post Conversation" className="relative mx-auto flex max-w-2xl flex-col gap-3 p-3 sm:p-4">
      {!valid ? <p role="alert">This post link is invalid.</p> : error ? <div role="alert" className="flex flex-col items-start gap-3"><p>{error}</p>{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { if (catalog.isError) void catalog.refetch(); else void query.refetch(); }}>Retry</Button>}</div> : !moderation || query.isPending ? <p role="status">Loading conversation…</p> : !root ? <p>This conversation is unavailable.</p> : <>
        <SocialAuthorThreadIndicator item={{ post: root.post }} thread={socialAuthorThreadRoot(root)} moderation={moderation} onOpen={navigation.openPost} />
        {!threadNavigation.focused ? parents.map(post => <SocialPostCard key={post.uri} item={{ post }} moderation={moderation} onOpen={() => openPost(post)} onOpenPost={openPost} />) : null}
        <SocialPostCard analyticsSurface="post-viewer" item={{ post: root.post, reply: root.parent ? { root: { ...root.post, $type: "app.bsky.feed.defs#postView" }, parent: AppBskyFeedDefs.isThreadViewPost(root.parent) ? { ...root.parent.post, $type: "app.bsky.feed.defs#postView" } : root.parent } : undefined }} moderation={moderation} detailedTimestamp onOpenPost={openPost} actions={<SocialPostActions post={root.post} moderation={moderation} onOpen={() => document.getElementById("social-post-replies")?.scrollIntoView({ block: "nearest" })} />} />
        <section id="social-post-replies" aria-label="Replies" className="flex flex-col gap-3">
          <h2 className="font-medium">Replies</h2>
          {!replies.length ? <p className="text-sm text-muted-foreground">No replies yet.</p> : replies.map(({ post, parent, depth, hasMore }) => {
            const content = moderateSocialPost(post, moderation).ui("contentList");
            const showMore = hasMore && !content.filter && !content.blur && !content.noOverride && AppBskyFeedPost.validateRecord(post.record).success;
            return <div key={post.uri} data-thread-post-uri={post.uri} data-reply-depth={depth} className={`min-w-0 ${depth > 0 ? "border-l-2 border-border pl-2 sm:pl-3" : ""} ${socialThreadReplyIndent(depth)}`}>
              <SocialPostCard item={{ post, reply: { root: { ...root.post, $type: "app.bsky.feed.defs#postView" }, parent: { ...parent, $type: "app.bsky.feed.defs#postView" } } }} moderation={moderation} onOpen={() => openPost(post)} onOpenPost={openPost} actions={<SocialPostActions post={post} moderation={moderation} onOpen={() => openPost(post)} />} />
              {showMore ? <Button data-thread-show-more variant="ghost" className="mt-2 min-h-11 text-muted-foreground" onClick={() => threadNavigation.openThread(post.uri, scrollContainer.current)}>Show More</Button> : null}
            </div>;
          })}
        </section>
      </>}
    </section></div>
  </div>;
}
