"use client";

import { RefreshCw } from "lucide-react";
import { useSearchParams } from "next/navigation";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useBlueskySocialTimeline } from "@/hooks/useBlueskySocialTimeline";
import { flattenSocialPages, SOCIAL_FOLLOWING_FEED, socialErrorMessage, socialFeedFromSearchParams, socialPostIdentity } from "@/lib/blueskySocialClient";
import { rememberOAuthReturnPath, SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { InteractiveSocialPost } from "./InteractiveSocialPost";
import { SocialTimelineSkeleton } from "./SocialTimelineSkeleton";
import { moderateSocialPost } from "./socialModeration";
import { SocialFeedsSheet } from "./SocialFeedsSheet";

export function SocialTimeline() {
  const params = useSearchParams();
  let feed = SOCIAL_FOLLOWING_FEED;
  let routeError: string | undefined;
  try { feed = socialFeedFromSearchParams(params); } catch (error) { routeError = socialErrorMessage(error); }
  const { session, signIn } = useAuth();
  const queryClient = useQueryClient();
  const [reauthorizing, setReauthorizing] = useState(false);
  const [reauthorizeError, setReauthorizeError] = useState(false);
  const catalog = useBlueskySocialCatalog();
  const moderation = !routeError && !catalog.isError ? catalog.data?.moderation : undefined;
  const timeline = useBlueskySocialTimeline(feed, moderation);
  const selected = catalog.data?.feeds.find(item => item.kind === feed.kind && item.uri === feed.uri) ?? feed;
  const posts = moderation ? flattenSocialPages(timeline.data?.pages ?? []).filter(item => !moderateSocialPost(item.post, moderation).ui("contentList").filter) : [];
  const error = routeError || (catalog.isError ? socialErrorMessage(catalog.error) : timeline.isError ? socialErrorMessage(timeline.error) : undefined);
  const loading = !error && (catalog.isPending || timeline.isPending);

  async function reauthorize() {
    if (!session) return;
    setReauthorizing(true);
    setReauthorizeError(false);
    rememberOAuthReturnPath();
    try { await signIn(session.did); } catch { setReauthorizing(false); setReauthorizeError(true); }
  }

  async function refresh() {
    const settings = await catalog.refetch();
    if (!settings.isError && session) {
      await queryClient.invalidateQueries({ queryKey: ["blueskySocial", session.did, "timeline"] });
    }
  }

  return <div className="flex min-h-0 w-full flex-1 flex-col">
    <FeedHeader title={selected.name} subtitle="Social">
      <SocialFeedsSheet />
      <Button variant="ghost" size="icon" aria-label="Refresh Social Feed" disabled={!!routeError || catalog.isFetching || timeline.isFetching} onClick={() => { void refresh(); }}>
        <RefreshCw data-icon="inline-start" />
      </Button>
    </FeedHeader>
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain" key={`${session?.did}:${feed.kind}:${feed.uri}`}>
      {error ? <section role="alert" className="mx-auto flex max-w-2xl flex-col items-start gap-3 p-6">
        <h2 className="text-lg font-semibold">Social Feed Unavailable</h2><p className="text-sm text-muted-foreground">{error}</p>
        {error === SCOPE_RECOVERY_MESSAGE ? <Button disabled={reauthorizing} onClick={() => { void reauthorize(); }}>{reauthorizing ? "Opening Login…" : "Log In Again"}</Button>
          : !routeError ? <Button variant="outline" onClick={() => { void refresh(); }}>Retry</Button> : null}
        {reauthorizeError ? <p className="text-sm text-destructive">Login could not be opened. Please try again.</p> : null}
      </section> : loading ? <SocialTimelineSkeleton /> : moderation ? <div className="mx-auto flex max-w-2xl flex-col gap-4 p-3 sm:p-4">
        {posts.map(item => <InteractiveSocialPost key={socialPostIdentity(item)} item={item} moderation={moderation} />)}
        {posts.length === 0 ? <section className="flex flex-col gap-2 px-2 py-10 text-center">
          <h2 className="text-lg font-semibold">No Posts to Show</h2>
          <p className="text-sm text-muted-foreground">{timeline.data?.pages.some(page => page.feed.length) ? "Posts on this page are hidden by your moderation settings." : "New posts will appear here when this feed updates."}</p>
        </section> : null}
        {timeline.hasNextPage ? <Button variant="outline" disabled={timeline.isFetchingNextPage} onClick={() => { void timeline.fetchNextPage(); }}>{timeline.isFetchingNextPage ? "Loading…" : "Load More"}</Button> : null}
      </div> : null}
    </div>
  </div>;
}
