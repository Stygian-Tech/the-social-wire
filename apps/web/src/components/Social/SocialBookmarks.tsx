"use client";

import { AppBskyFeedDefs } from "@atproto/api";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { useBlueskyBookmarks } from "@/hooks/useBlueskyBookmarks";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { InteractiveSocialPost } from "./InteractiveSocialPost";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialTimelineSkeleton } from "./SocialTimelineSkeleton";

export function SocialBookmarks() {
  const catalog = useBlueskySocialCatalog();
  const moderation = catalog.isError ? undefined : catalog.data?.moderation;
  const query = useBlueskyBookmarks(moderation);
  const error = catalog.isError ? catalog.error : query.isError ? query.error : undefined;
  const message = error ? socialErrorMessage(error) : undefined;
  const seen = new Set<string>();
  const bookmarks = query.data?.pages.flatMap(page => page.bookmarks).filter(bookmark => {
    if (seen.has(bookmark.subject.uri)) return false;
    seen.add(bookmark.subject.uri); return true;
  }) ?? [];
  return <section className="flex min-h-0 w-full flex-col">
    <FeedHeader title="Bookmarks" subtitle="Social" />
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain">
      {message ? <div role="alert" className="mx-auto max-w-2xl space-y-3 p-6"><h2 className="font-semibold">Bookmarks Unavailable</h2><p>{message}</p>{message === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button onClick={() => { if (catalog.isError) void catalog.refetch(); else void query.refetch(); }}>Retry</Button>}</div>
        : catalog.isPending || query.isPending ? <SocialTimelineSkeleton />
        : <div className="mx-auto flex max-w-2xl flex-col gap-4 p-3 sm:p-4">
          {bookmarks.length === 0 ? <p className="py-10 text-center text-muted-foreground">No bookmarks yet. Save a post using its Bookmark action.</p> : null}
          {moderation ? bookmarks.map(bookmark => AppBskyFeedDefs.isPostView(bookmark.item)
            ? <InteractiveSocialPost key={bookmark.subject.uri} item={{ post: { ...bookmark.item, viewer: { ...bookmark.item.viewer, bookmarked: true } } }} moderation={moderation} />
            : <div key={bookmark.subject.uri} className="rounded-2xl border p-4 text-muted-foreground">Bookmarked post unavailable.</div>) : null}
          {query.hasNextPage ? <Button variant="outline" disabled={query.isFetchingNextPage} onClick={() => { void query.fetchNextPage(); }}>{query.isFetchingNextPage ? "Loading…" : "Load More"}</Button> : null}
        </div>}
    </div>
  </section>;
}
