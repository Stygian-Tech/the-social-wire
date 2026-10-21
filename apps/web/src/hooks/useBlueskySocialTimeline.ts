"use client";

import { useInfiniteQuery, useQueryClient, type InfiniteData } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";
import type { ModerationOpts } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { getBlueskySocialPage, hydrateBlueskySocialPage, nextSocialCursor, type SocialFeed, type BlueskySocialPage } from "@/lib/blueskySocialClient";
import { coalesceFeedFirstPage } from "@/lib/feedRefreshCoordinator";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useBlueskySocialTimeline(feed: SocialFeed, moderation: ModerationOpts | undefined) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const client = useQueryClient();
  const key = ["blueskySocial", session?.did ?? "", "timeline", oauthSessionReloadSeq, feed.kind, feed.uri, moderation?.prefs.labelers.map(labeler => labeler.did)];
  const refreshScope = JSON.stringify(key);
  const refreshContext = useMemo(() => ({ scope: refreshScope }), [refreshScope]);
  const currentRefreshContext = useRef<typeof refreshContext | undefined>(refreshContext);
  useEffect(() => {
    currentRefreshContext.current = refreshContext;
    return () => { currentRefreshContext.current = undefined; };
  }, [refreshContext]);
  const [refreshState, setRefreshState] = useState<{ context: typeof refreshContext; scope: string; pending: boolean; error?: unknown }>();
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
    // Returning to a post must restore the same loaded feed, even when stale.
    // New feed membership is loaded through refreshFirstPage / Home refresh.
    refetchOnMount: false,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  });
  const pages = query.data?.pages;
  useEffect(() => {
    const oauth = getOAuthSession();
    if (!oauth || !moderation || moderation.userDid !== oauth.did || !pages?.length || pages.every(page => decoratedPages.has(page))) return;
    const controller = new AbortController();
    // Yield to the first content frame before optional upstream decoration.
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
      }).catch(() => { /* Keep moderated posts when optional reply context is unavailable. */ });
    }, 0);
    return () => { window.clearTimeout(timer); controller.abort(); };
    // The key follows the same pages; decoration must not restart on every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pages, client, getOAuthSession, moderation]);
  const refreshFirstPage = async (freshModeration = moderation) => {
    const oauth = getOAuthSession();
    const freshKey = ["blueskySocial", oauth?.did ?? session?.did ?? "", "timeline", oauthSessionReloadSeq, feed.kind, feed.uri, freshModeration?.prefs.labelers.map(labeler => labeler.did)];
    const requestScope = JSON.stringify(freshKey);
    setRefreshState({ context: refreshContext, scope: requestScope, pending: true });
    try {
      if (!oauth || !freshModeration || freshModeration.userDid !== oauth.did) throw new Error(SCOPE_RECOVERY_MESSAGE);
      const page = await coalesceFeedFirstPage(client, oauth, freshKey, () => getBlueskySocialPage({ session: oauth, feed, moderation: freshModeration, deferReplyHydration: true }));
      if (getOAuthSession() !== oauth || currentRefreshContext.current !== refreshContext || refreshContext.scope !== requestScope) return;
      client.setQueryData<InfiniteData<BlueskySocialPage>>(freshKey, { pages: [page], pageParams: [undefined] });
      setRefreshState({ context: refreshContext, scope: requestScope, pending: false });
    } catch (error) {
      // Retain already moderated pages, but make refresh failures retryable.
      // Results from a replaced account/session never affect its successor.
      if (getOAuthSession() === oauth && currentRefreshContext.current === refreshContext && refreshContext.scope === requestScope) setRefreshState({ context: refreshContext, scope: requestScope, pending: false, error });
    }
  };
  return { ...query, refreshFirstPage, refreshError: refreshState?.context === refreshContext && refreshState.scope === refreshScope ? refreshState.error : undefined, isRefreshing: refreshState?.context === refreshContext && refreshState.scope === refreshScope && refreshState.pending };
}

const decoratedPages = new WeakSet<BlueskySocialPage>();
