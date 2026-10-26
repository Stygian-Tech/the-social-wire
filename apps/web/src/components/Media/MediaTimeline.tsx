"use client";

import { RefreshCw } from "lucide-react";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { SocialPostCard } from "@/components/Social/SocialPostCard";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";
import { moderateSocialPost } from "@/components/Social/socialModeration";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useBlueskySocialTimeline } from "@/hooks/useBlueskySocialTimeline";
import { SOCIAL_FOLLOWING_FEED } from "@/lib/blueskySocialClient";
import { uniqueMediaPosts, type MediaMode } from "@/lib/mediaFeedClient";
import { isSocialInteractionHidden } from "@/lib/socialInteractionModeration";

export function MediaTimeline({ mode }: { mode: MediaMode }) {
  const { session } = useAuth();
  const catalog = useBlueskySocialCatalog();
  const moderation = catalog.data?.moderation.userDid === session?.did ? catalog.data?.moderation : undefined;
  const timeline = useBlueskySocialTimeline(SOCIAL_FOLLOWING_FEED, moderation, mode);
  const title = mode === "photos" ? "Photos" : "Short Videos";
  const posts = moderation ? uniqueMediaPosts(timeline.data?.pages ?? []).filter(item => {
    const content = moderateSocialPost(item.post, moderation).ui("contentList");
    return !content.filter && !isSocialInteractionHidden(item, moderation);
  }) : [];
  const error = catalog.error || timeline.error || timeline.refreshError;
  const refresh = () => timeline.refreshFirstPage(async () => (await catalog.refetchSafety()).moderation);
  const busy = timeline.isFetching || timeline.isRefreshing;
  return <div className="flex min-h-0 w-full flex-1 flex-col">
    <FeedHeader title={title} subtitle="Media · Bluesky Following">
      <Button variant="ghost" size="icon" aria-label={`Refresh ${title}`} disabled={busy} onClick={() => { void refresh(); }}><RefreshCw /></Button>
    </FeedHeader>
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain pb-24" key={`${session?.did}:${mode}`}>
      <div className="mx-auto flex max-w-2xl flex-col gap-4 p-3 sm:p-4">
        <p className="text-sm text-muted-foreground">{mode === "photos" ? "Live photos and galleries from your Bluesky Following feed." : "Live portrait videos from your Bluesky Following feed. Duration may vary; videos without portrait dimensions are excluded."} Spark and Grain feeds are not connected. Posts cannot be attributed to Flashes.</p>
        {error ? <section role="alert" className="flex flex-col items-start gap-3 rounded-2xl border p-4"><h2 className="font-semibold">Media Feed Unavailable</h2><p className="text-sm">{error instanceof Error ? error.message : "Please try again."}</p><Button disabled={busy} variant="outline" onClick={() => { void refresh(); }}>Retry</Button></section> : null}
        {!error && (!moderation || timeline.isPending) ? <SocialTimelineSkeleton /> : moderation ? <>
          {posts.map(item => <SocialPostCard key={item.post.uri} item={item} moderation={moderation} />)}
          {!posts.length && !busy && !error ? <section role="status" className="py-10 text-center"><h2 className="text-lg font-semibold">No {title} on These Pages</h2><p className="text-sm text-muted-foreground">{timeline.hasNextPage ? "Load more to keep looking through your Following feed." : "New media will appear when people you follow share it."}</p></section> : null}
          {timeline.hasNextPage ? <Button variant="outline" disabled={busy} onClick={() => { void timeline.fetchNextPage(); }}>{timeline.isFetchingNextPage ? "Loading…" : "Load More"}</Button> : null}
        </> : null}
      </div>
    </div>
  </div>;
}
