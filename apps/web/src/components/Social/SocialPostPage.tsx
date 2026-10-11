"use client";

import { useSearchParams } from "next/navigation";
import { AppBskyFeedDefs } from "@atproto/api";
import { ArrowLeft } from "lucide-react";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useBlueskyPostThread } from "@/hooks/useBlueskyPostThread";
import { useSocialPostNavigation } from "@/hooks/useSocialPostNavigation";
import { isSocialPostUri } from "@/lib/socialPostNavigation";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialPostCard } from "./SocialPostCard";
import { SocialPostActions } from "./SocialPostActions";

export function SocialPostPage() {
  const { session } = useAuth();
  const params = useSearchParams();
  const uri = params?.get("uri");
  return <SocialPostViewer key={`${session?.did ?? ""}:${uri}`} uri={uri} />;
}

function SocialPostViewer({ uri }: { uri: string | null | undefined }) {
  const { session } = useAuth();
  const navigation = useSocialPostNavigation();
  const catalog = useBlueskySocialCatalog();
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === session?.did ? catalog.data?.moderation : undefined;
  const valid = isSocialPostUri(uri);
  const query = useBlueskyPostThread(valid ? uri : undefined, moderation);
  const thread = !query.isError && moderation ? query.data?.thread : undefined;
  const root: AppBskyFeedDefs.ThreadViewPost | undefined = AppBskyFeedDefs.isThreadViewPost(thread) ? thread as AppBskyFeedDefs.ThreadViewPost : undefined;
  const parents: AppBskyFeedDefs.PostView[] = [];
  const seen = new Set(root ? [root.post.uri] : []);
  let parent = root?.parent;
  while (AppBskyFeedDefs.isThreadViewPost(parent) && parents.length < 80 && !seen.has(parent.post.uri)) {
    seen.add(parent.post.uri); parents.unshift(parent.post); parent = parent.parent;
  }
  const replies: AppBskyFeedDefs.PostView[] = [];
  function collect(nodes: AppBskyFeedDefs.ThreadViewPost["replies"], depth = 0) {
    if (depth > 6 || replies.length >= 100) return;
    for (const node of nodes ?? []) if (AppBskyFeedDefs.isThreadViewPost(node) && !seen.has(node.post.uri)) {
      if (replies.length >= 100) break;
      seen.add(node.post.uri); replies.push(node.post); collect(node.replies, depth + 1);
    }
  }
  collect(root?.replies);
  const error = catalog.isError ? socialErrorMessage(catalog.error) : query.isError ? socialErrorMessage(query.error) : undefined;
  const openPost = (post: AppBskyFeedDefs.PostView) => navigation.openPost(post.uri);
  return <div className="flex min-h-0 w-full flex-1 flex-col">
    <FeedHeader title="Post" subtitle="Conversation" leading={<Button variant="ghost" size="icon" aria-label="Back" title="Back" className="min-h-11 min-w-11" onClick={navigation.back}><ArrowLeft aria-hidden="true" /></Button>} />
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain"><section aria-label="Post Conversation" className="mx-auto flex max-w-2xl flex-col gap-3 p-3 sm:p-4">
      {!valid ? <p role="alert">This post link is invalid.</p> : error ? <div role="alert" className="flex flex-col items-start gap-3"><p>{error}</p>{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { if (catalog.isError) void catalog.refetch(); else void query.refetch(); }}>Retry</Button>}</div> : !moderation || query.isPending ? <p role="status">Loading conversation…</p> : !root ? <p>This conversation is unavailable.</p> : <>
        {parents.map(post => <SocialPostCard key={post.uri} item={{ post }} moderation={moderation} onOpen={() => openPost(post)} onOpenPost={openPost} />)}
        <SocialPostCard item={{ post: root.post }} moderation={moderation} detailedTimestamp onOpenPost={openPost} actions={<SocialPostActions post={root.post} moderation={moderation} onOpen={() => document.getElementById("social-post-replies")?.scrollIntoView({ block: "nearest" })} />} />
        <section id="social-post-replies" aria-label="Replies" className="flex flex-col gap-3"><h2 className="font-medium">Replies</h2>{!replies.length ? <p className="text-sm text-muted-foreground">No replies yet.</p> : replies.map(post => <SocialPostCard key={post.uri} item={{ post }} moderation={moderation} onOpen={() => openPost(post)} onOpenPost={openPost} actions={<SocialPostActions post={post} moderation={moderation} onOpen={() => openPost(post)} />} />)}</section>
      </>}
    </section></div>
  </div>;
}
