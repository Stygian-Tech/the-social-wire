"use client";

import { useInfiniteQuery, useQueryClient, type InfiniteData } from "@tanstack/react-query";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { ModerationOpts } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { getBlueskySocialPage, hydrateBlueskySocialPage, nextSocialCursor, type SocialFeed, type BlueskySocialPage } from "@/lib/blueskySocialClient";
import { coalesceFeedFirstPage } from "@/lib/feedRefreshCoordinator";
import { socialModerationScope, socialTimelineKey } from "@/lib/socialQueryScope";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useBlueskySocialTimeline(feed: SocialFeed, moderation: ModerationOpts | undefined) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const client = useQueryClient();
  const key = socialTimelineKey(session?.did ?? "", feed, moderation);
  const moderationScope = socialModerationScope(moderation);
  const routeScope = JSON.stringify([session?.did, feed.kind, feed.uri, oauthSessionReloadSeq]);
  // Occurrence identity also retires work across A -> B -> A navigation.
  const route = useMemo(() => ({ scope: routeScope }), [routeScope]);
  const [safety, setSafety] = useState({ scope: moderationScope, generation: 0 });
  if (safety.scope !== moderationScope) setSafety({ scope: moderationScope, generation: safety.generation + 1 });
  const current = useRef({ route: route as object | undefined, safety, generation: 0 });
  useLayoutEffect(() => {
    current.current = { route, safety, generation: safety.generation };
  }, [route, safety]);
  useLayoutEffect(() => () => { current.current.route = undefined; }, []);
  type RefreshOwner = { route: object; generation: number; source: string; target?: string };
  const ownsRefresh = (owner: RefreshOwner) => current.current.route === owner.route && (
    (current.current.generation === owner.generation && current.current.safety.scope === owner.source)
    || (current.current.generation === owner.generation + 1 && current.current.safety.scope === owner.target)
  );
  const [refreshState, setRefreshState] = useState<{ owner: RefreshOwner; pending: boolean; error?: unknown }>();
  const query = useInfiniteQuery({
    queryKey: key,
    initialData: () => {
      const legacy = client.getQueryCache().findAll({ queryKey: key.slice(0, 6) }).find(candidate => {
        const labelers = candidate.queryKey[6];
        return !!candidate.state.data && candidate.queryKey.length === key.length && Array.isArray(labelers) && labelers.every(did => typeof did === "string")
          && JSON.stringify([...new Set(labelers)].sort()) === JSON.stringify(key[6]);
      });
      return legacy?.state.data as InfiniteData<BlueskySocialPage, string | undefined> | undefined;
    },
    initialDataUpdatedAt: 1,
    enabled: !!session && moderation?.userDid === session.did,
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== session?.did || !moderation) throw new Error("Your account changed. Please reload this feed.");
      const fetchPage = () => getBlueskySocialPage({ session: oauth, feed, moderation, cursor: pageParam, signal, deferReplyHydration: true });
      return pageParam === undefined ? coalesceFeedFirstPage(client, requestOwner(route, oauth), [...key, moderationScope, safety.generation], fetchPage, signal) : fetchPage();
    },
    getNextPageParam: (lastPage, _pages, _lastParam, pageParams) => nextSocialCursor(lastPage, pageParams),
    retry: false,
    staleTime: 30_000,
    gcTime: 7 * 24 * 60 * 60 * 1000,
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
  const refreshFirstPage = async (loadModeration: ModerationOpts | (() => Promise<ModerationOpts>) | undefined = moderation) => {
    const oauth = getOAuthSession();
    const owner: RefreshOwner = { route, generation: current.current.generation, source: moderationScope };
    if (current.current.route !== route) return;
    setRefreshState({ owner, pending: true });
    try {
      const freshModeration = typeof loadModeration === "function" ? await loadModeration() : loadModeration;
      if (!oauth || !freshModeration || freshModeration.userDid !== oauth.did) throw new Error(SCOPE_RECOVERY_MESSAGE);
      owner.target = socialModerationScope(freshModeration);
      if (getOAuthSession() !== oauth || !ownsRefresh(owner)) return;
      const freshKey = socialTimelineKey(oauth.did, feed, freshModeration);
      const page = await coalesceFeedFirstPage(client, requestOwner(route, oauth), [...freshKey, owner.target, owner.generation + (owner.target === owner.source ? 0 : 1)], async () => {
        // Retire pagination before replacing the head, retaining moderation ownership.
        await client.cancelQueries({ queryKey: freshKey, exact: true });
        return getBlueskySocialPage({ session: oauth, feed, moderation: freshModeration, deferReplyHydration: true });
      });
      // Allow the verified catalog target, but retire further settings changes.
      const catalogScope = socialModerationScope(client.getQueryData<{ moderation: ModerationOpts }>(["blueskySocial", oauth.did, "catalog", "cache-v1"])?.moderation);
      const targetIsCurrent = current.current.safety.scope === owner.target
        || (typeof loadModeration === "function" && current.current.safety.scope === owner.source && catalogScope === owner.target);
      if (getOAuthSession() !== oauth || !ownsRefresh(owner) || !targetIsCurrent) return;
      client.setQueryData<InfiniteData<BlueskySocialPage>>(freshKey, { pages: [page], pageParams: [undefined] });
      setRefreshState({ owner, pending: false });
    } catch (error) {
      if (getOAuthSession() === oauth && ownsRefresh(owner)) setRefreshState({ owner, pending: false, error });
    }
  };
  const renderedGeneration = safety.generation;
  const activeRefresh = refreshState && refreshState.owner.route === route && (
    (refreshState.owner.generation === renderedGeneration && refreshState.owner.source === moderationScope)
    || (refreshState.owner.generation + 1 === renderedGeneration && refreshState.owner.target === moderationScope)
  ) ? refreshState : undefined;
  return { ...query, refreshFirstPage, refreshError: activeRefresh?.error, isRefreshing: activeRefresh?.pending ?? false };
}

const decoratedPages = new WeakSet<BlueskySocialPage>();

const requestOwners = new WeakMap<object, WeakMap<object, object>>();
/** A new visit or OAuth object cannot join a retired visit's page request. */
function requestOwner(route: object, oauth: object): object {
  let sessions = requestOwners.get(route);
  if (!sessions) { sessions = new WeakMap(); requestOwners.set(route, sessions); }
  let owner = sessions.get(oauth);
  if (!owner) { owner = {}; sessions.set(oauth, owner); }
  return owner;
}
