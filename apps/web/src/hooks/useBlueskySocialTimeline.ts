"use client";

import { useInfiniteQuery, useQueryClient, type InfiniteData } from "@tanstack/react-query";
import { useEffect } from "react";
import type { ModerationOpts } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { getBlueskySocialPage, hydrateBlueskySocialPage, nextSocialCursor, type SocialFeed, type BlueskySocialPage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useBlueskySocialTimeline(feed: SocialFeed, moderation: ModerationOpts | undefined) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const client = useQueryClient();
  const key = ["blueskySocial", session?.did ?? "", "timeline", oauthSessionReloadSeq, feed.kind, feed.uri, moderation?.prefs.labelers.map(labeler => labeler.did)];
  const query = useInfiniteQuery({
    queryKey: key,
    enabled: !!session && moderation?.userDid === session.did,
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== session?.did || !moderation) throw new Error("Your account changed. Please reload this feed.");
      return getBlueskySocialPage({ session: oauth, feed, moderation, cursor: pageParam, signal, deferReplyHydration: true });
    },
    getNextPageParam: (lastPage, _pages, _lastParam, pageParams) => nextSocialCursor(lastPage, pageParams),
    retry: false,
    staleTime: 30_000,
  });
  const pages = query.data?.pages;
  useEffect(() => {
    const oauth = getOAuthSession();
    if (!oauth || !moderation || moderation.userDid !== oauth.did || !pages?.length || pages.every(page => decoratedPages.has(page))) return;
    const controller = new AbortController();
    // Paint replies and their Show Thread fallback before optional context arrives.
    const timer = window.setTimeout(() => {
      void (async () => {
        const hydratedPages: BlueskySocialPage[] = [];
        for (const page of pages) {
          controller.signal.throwIfAborted();
          if (decoratedPages.has(page)) { hydratedPages.push(page); continue; }
          const hydrated = await hydrateBlueskySocialPage(oauth, page, controller.signal, moderation);
          decoratedPages.add(hydrated);
          hydratedPages.push(hydrated);
        }
        return hydratedPages;
      })().then(hydrated => {
        if (controller.signal.aborted || getOAuthSession() !== oauth) return;
        client.setQueryData<InfiniteData<BlueskySocialPage>>(key, current =>
          current?.pages === pages ? { ...current, pages: hydrated } : current);
      }).catch(() => { /* Keep Show Thread available when optional context fails. */ });
    }, 0);
    return () => { window.clearTimeout(timer); controller.abort(); };
    // The key follows the same pages; avoid restarting decoration on every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pages, client, getOAuthSession, moderation]);
  return query;
}

const decoratedPages = new WeakSet<BlueskySocialPage>();
