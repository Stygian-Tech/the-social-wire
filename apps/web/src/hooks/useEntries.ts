"use client";

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  isCancelledError,
  onlineManager,
  useInfiniteQuery,
  useQuery,
  useQueryClient,
  type InfiniteData,
  type QueryClient,
} from "@tanstack/react-query";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import {
  isStandardSiteEntryId,
  resolveEntryOpenUrlFromPds,
} from "@/lib/resolveEntryOpenUrl";
import type { EntryListItem, EntryDetail } from "@/lib/atprotoClient";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import { prefetchCachedImages } from "@/lib/imageBlobCache";
import {
  mergeFeedRefreshForFilter,
  unreadFeedPlaceholder,
} from "@/lib/feedCacheMerge";
import {
  getEntryFromAppView,
  isThinAppViewEnabled,
  listAggregateFeedFromAppView,
  shouldRetryAppViewRequest,
  type AggregateAppViewFeed,
} from "@/lib/thinAppViewClient";
import {
  dummyEntriesForAggregateFeed,
  dummyEntriesForPublication,
  dummyEntryDetail,
  isDummyReaderDataEnabled,
} from "@/lib/dummyReaderData";
import { recordClientPerformance } from "@/lib/clientPerformanceTelemetry";
import { useAuth } from "./useAuth";
import { coalesceFeedFirstPage, getFeedRefreshRevision, readFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";
import { refreshPublicationUnreadCount } from "@/lib/feedRefresh";
import { useFeedFirstContentTiming } from "./useFeedFirstContentTiming";

export type { EntryListItem, EntryDetail };

export const ENTRIES_QUERY_KEY = (viewerDid: string, publicationId: string) =>
  ["entries", viewerDid, publicationId] as const;
export const AGGREGATE_ENTRIES_QUERY_KEY = (
  viewerDid: string,
  feed: AggregateAppViewFeed
) => ["aggregateEntries", viewerDid, feed.kind, feed.id ?? ""] as const;
export const ENTRY_DETAIL_QUERY_KEY = (entryId: string) =>
  ["entry", entryId] as const;

export type EntriesPage = { entries: EntryListItem[]; cursor?: string };

/** Matches {@link useEntries} `staleTime` / `prefetchInfiniteQuery` for entry lists. */
export const ENTRIES_QUERY_STALE_MS = 30_000;

/** Stop pagination when the server repeats a cursor, including duplicate rows. */
export function entriesNextPageParam(
  lastPage: EntriesPage,
  _allPages: EntriesPage[],
  lastPageParam: string | undefined,
  allPageParams: (string | undefined)[] = [],
): string | undefined {
  const cursor = lastPage.cursor;
  if (!cursor) return undefined;
  if (lastPageParam === cursor || allPageParams.includes(cursor)) {
    return undefined;
  }
  return cursor;
}

/**
 * Fetches a single infinite-query page of entries from Thin AppView.
 */
export async function fetchEntriesInfinitePage(args: {
  normalizedPublicationKey: string;
  pageParam: string | undefined;
  signal?: AbortSignal;
  oauthSession: OAuthSession;
  viewerDid: string;
  articleFilter?: ArticleListFilter;
  queryClient?: QueryClient;
  maxEntries?: number;
  /** Skips PDS enroll on page 1 (lighter proactive refresh polls). */
  skipEnroll?: boolean;
}): Promise<EntriesPage> {
  const {
    normalizedPublicationKey: normalizedKey,
    pageParam,
    signal,
    oauthSession,
    viewerDid,
    articleFilter = "all",
    maxEntries,
    skipEnroll = false,
  } = args;

  if (!normalizedKey) return { entries: [], cursor: undefined };

  if (!isThinAppViewEnabled()) {
    throw new Error("Thin AppView is required for entry lists");
  }

  void viewerDid;
  void args.queryClient;
  void maxEntries;
  void skipEnroll;
  return listAggregateFeedFromAppView({
    feed: { kind: "publication", id: normalizedKey },
    cursor: pageParam,
    filter: articleFilter,
    oauthSession,
    signal,
  });
}

/** Query must reject obsolete data, while public refetch reports a skipped write. */
class SupersededFeedRefreshError extends Error {
  constructor() {
    super("Feed refresh superseded");
    this.name = "AbortError";
  }
}

function captureFeedRequestGuard(
  client: QueryClient,
  queryKey: readonly string[],
  oauth: OAuthSession,
  getOAuthSession: () => OAuthSession | null,
  signal: AbortSignal,
): () => void {
  const query = client.getQueryCache().find({ queryKey, exact: true });
  const revision = getFeedRefreshRevision(client, queryKey);
  const readRevision = readFeedRefreshRevision(client, oauth);
  return () => {
    if (signal.aborted || getOAuthSession() !== oauth || oauth.did !== queryKey[1] ||
      getFeedRefreshRevision(client, queryKey) !== revision ||
      readFeedRefreshRevision(client, oauth) !== readRevision ||
      client.getQueryCache().find({ queryKey, exact: true }) !== query) {
      throw new SupersededFeedRefreshError();
    }
  };
}

const pendingLifecycleRefreshes = new WeakMap<QueryClient, Map<string, { isCurrent: () => boolean }>>();

/** Keep lifecycle refreshes in the query's retry/cancellation state without
 * infinite-query's full-page replacement. Initial reads and pagination still use
 * the observer's infinite query function. */
function useGuardedFeedRefresh(args: {
  queryKey: readonly string[];
  feed: AggregateAppViewFeed | null;
  articleFilter: ArticleListFilter;
  enabled: boolean;
  hasData: boolean;
  isFetchedAfterMount: boolean;
  oauthSessionReloadSeq: number;
  getOAuthSession: () => OAuthSession | null;
  fetchInitial: () => Promise<unknown>;
}) {
  const { queryKey, feed, articleFilter, enabled, hasData, isFetchedAfterMount, oauthSessionReloadSeq, getOAuthSession, fetchInitial } = args;
  const queryClient = useQueryClient();
  const oauthSession = getOAuthSession();
  const reloadSeq = useRef(oauthSessionReloadSeq);
  useLayoutEffect(() => { reloadSeq.current = oauthSessionReloadSeq; }, [oauthSessionReloadSeq]);
  const currentScope = useRef<{ queryKey: readonly string[]; enabled: boolean } | null>(null);
  useLayoutEffect(() => {
    const owner = { queryKey, enabled };
    currentScope.current = owner;
    return () => { if (currentScope.current === owner) currentScope.current = null; };
  }, [enabled, queryKey]);
  const mountedScope = useRef<{
    queryKey: readonly string[];
    oauthSession: OAuthSession;
    reloadSeq: number;
  } | null>(null);
  const refresh = useCallback(async (replaceSession = false) => {
    const oauth = getOAuthSession();
    if (!enabled || !oauth || !feed) return false;
    const cachedQuery = queryClient.getQueryCache().find({ queryKey, exact: true });
    const revision = getFeedRefreshRevision(queryClient, queryKey);
    const readRevision = readFeedRefreshRevision(queryClient, oauth);
    const isCurrent = () => currentScope.current?.queryKey === queryKey &&
      currentScope.current.enabled && getOAuthSession() === oauth &&
      reloadSeq.current === oauthSessionReloadSeq &&
      getFeedRefreshRevision(queryClient, queryKey) === revision &&
      readFeedRefreshRevision(queryClient, oauth) === readRevision &&
      queryClient.getQueryCache().find({ queryKey, exact: true }) === cachedQuery;
    if (!cachedQuery?.state.data) {
      if (replaceSession) {
        await queryClient.cancelQueries({ queryKey, exact: true });
        if (!isCurrent()) return false;
      }
      await fetchInitial();
      return isCurrent();
    }
    const refreshStartedAt = performance.now();
    let pending = pendingLifecycleRefreshes.get(queryClient);
    if (!pending) { pending = new Map(); pendingLifecycleRefreshes.set(queryClient, pending); }
    const scope = JSON.stringify(queryKey);
    const previous = pending.get(scope);
    if (previous && !previous.isCurrent() || replaceSession && cachedQuery.state.fetchStatus !== "idle") {
      // Confirmation can start a fetch without a lifecycle-map owner. Session
      // replacement must retire that retryer too before starting its successor.
      await queryClient.cancelQueries({ queryKey, exact: true });
      if (!isCurrent()) return false;
    }
    const owner = { isCurrent };
    pending.set(scope, owner);
    const fetchMerged = async (signal: AbortSignal): Promise<InfiniteData<EntriesPage>> => {
      // Query.fetch(undefined) can reuse this installed function after a read
      // confirmation. Snapshots belong to this request, not the installing call.
      const requestSession = getOAuthSession();
      if (!requestSession || requestSession.did !== queryKey[1]) {
        throw new SupersededFeedRefreshError();
      }
      const assertCurrent = captureFeedRequestGuard(queryClient, queryKey, requestSession, getOAuthSession, signal);
      const requestReloadSeq = reloadSeq.current;
      const fresh = await coalesceFeedFirstPage(queryClient, requestSession, queryKey, () =>
        listAggregateFeedFromAppView({ feed, filter: articleFilter, oauthSession: requestSession, signal }),
        signal,
      );
      assertCurrent();
      if (reloadSeq.current !== requestReloadSeq) throw new SupersededFeedRefreshError();
      const current = queryClient.getQueryData<InfiniteData<EntriesPage>>(queryKey);
      return mergeFeedRefreshForFilter(current, fresh, articleFilter);
    };
    try {
      await queryClient.fetchQuery({
        queryKey,
        staleTime: 0,
        retry: shouldRetryAppViewRequest,
        queryFn: ({ signal }) => fetchMerged(signal),
        // An infinite query retains its behavior even through fetchQuery. The
        // query persister wraps the entire fetch, allowing a first-page merge
        // while Query still owns cancellation, retries, and the error state.
        persister: (_fetch, { signal }) => fetchMerged(signal),
      });
    } catch (error) {
      if (isCancelledError(error) || error instanceof SupersededFeedRefreshError) return false;
      throw error;
    } finally {
      if (pending.get(scope) === owner) pending.delete(scope);
    }
    if (!isCurrent()) return false;
    void recordClientPerformance(oauth, {
      event: "fresh_merge",
      durationMs: performance.now() - refreshStartedAt,
      feedType: feed.kind === "publication" ? "publication" : "aggregate",
      cacheState: "hit",
      outcome: "success",
    }).catch(() => undefined);
    if (feed.kind === "publication" && feed.id) {
      await refreshPublicationUnreadCount({ queryClient, viewerDid: oauth.did, publicationId: feed.id, oauthSession: oauth });
    }
    return true;
  }, [articleFilter, enabled, feed, fetchInitial, getOAuthSession, oauthSessionReloadSeq, queryClient, queryKey]);

  useEffect(() => {
    if (!enabled || !oauthSession) return;
    const previous = mountedScope.current;
    if (previous?.queryKey === queryKey && previous.oauthSession === oauthSession &&
      previous.reloadSeq === oauthSessionReloadSeq) return;
    const sessionChanged = previous?.queryKey === queryKey &&
      (previous.oauthSession !== oauthSession || previous.reloadSeq !== oauthSessionReloadSeq);
    mountedScope.current = { queryKey, oauthSession, reloadSeq: oauthSessionReloadSeq };
    const state = queryClient.getQueryState(queryKey);
    if (sessionChanged || hasData && !isFetchedAfterMount && state &&
      (state.isInvalidated || Date.now() - state.dataUpdatedAt >= ENTRIES_QUERY_STALE_MS)) {
      void refresh(sessionChanged).catch(() => undefined); // query exposes the error with cached rows
    }
  }, [enabled, hasData, isFetchedAfterMount, oauthSession, oauthSessionReloadSeq, queryClient, queryKey, refresh]);

  useEffect(() => onlineManager.subscribe((online) => {
    if (!online || !enabled) return;
    const state = queryClient.getQueryState(queryKey);
    if (state?.data && (state.isInvalidated || Date.now() - state.dataUpdatedAt >= ENTRIES_QUERY_STALE_MS)) {
      void refresh().catch(() => undefined);
    }
  }), [enabled, queryClient, queryKey, refresh]);

  return useCallback(() => refresh(), [refresh]);
}

/**
 * Returns a paginated list of entries for a publication sidebar selection.
 */
export function useEntries(
  publicationKey: string | null,
  articleFilter: ArticleListFilter = "all"
) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const queryClient = useQueryClient();
  const dummyReaderDataEnabled = isDummyReaderDataEnabled();
  const normalizedKey = publicationKey ? normalizeAtRepoParam(publicationKey) : null;
  const viewerDid = session?.did ?? "";
  const entriesQueryKey = useMemo(
    () =>
      [
        ...ENTRIES_QUERY_KEY(viewerDid, normalizedKey ?? ""),
        articleFilter,
      ] as const,
    [articleFilter, normalizedKey, viewerDid]
  );
  const paintStartedRef = useRef(0);
  const telemetryKeyRef = useRef<string | null>(null);
  const errorTelemetryKeyRef = useRef<string | null>(null);
  const paintKey = `${viewerDid}:${normalizedKey ?? ""}:${articleFilter}`;
  useEffect(() => {
    paintStartedRef.current = performance.now();
  }, [paintKey]);

  const query = useInfiniteQuery({
    queryKey: entriesQueryKey,
    queryFn: async ({ pageParam, signal }) => {
      if (!normalizedKey) return { entries: [], cursor: undefined };
      if (dummyReaderDataEnabled) {
        return {
          entries: dummyEntriesForPublication(normalizedKey),
          cursor: undefined,
        };
      }
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const fetchPage = () => fetchEntriesInfinitePage({
        normalizedPublicationKey: normalizedKey,
        pageParam,
        signal,
        oauthSession: oauth,
        viewerDid,
        articleFilter,
        queryClient,
      });
      const assertCurrent = captureFeedRequestGuard(queryClient, entriesQueryKey, oauth, getOAuthSession, signal);
      const page = await (pageParam ? fetchPage() : coalesceFeedFirstPage(queryClient, oauth, entriesQueryKey, fetchPage, signal));
      assertCurrent();
      return page;
    },
    initialPageParam: undefined as string | undefined,
    initialData:
      dummyReaderDataEnabled && normalizedKey
        ? {
            pages: [
              {
                entries: dummyEntriesForPublication(normalizedKey),
                cursor: undefined,
              },
            ],
            pageParams: [undefined],
          }
        : undefined,
    placeholderData:
      articleFilter === "unread"
        ? () =>
            unreadFeedPlaceholder(
              queryClient.getQueryData<
                InfiniteData<EntriesPage, string | undefined>
              >([
                ...ENTRIES_QUERY_KEY(viewerDid, normalizedKey ?? ""),
                "all",
              ])
            )
        : undefined,
    getNextPageParam: entriesNextPageParam,
    enabled:
      !!normalizedKey &&
      !!session &&
      !!viewerDid,
    staleTime: ENTRIES_QUERY_STALE_MS,
    refetchOnMount: false,
    refetchOnReconnect: false,
    refetchOnWindowFocus: false,
    gcTime: 1000 * 60 * 60 * 24,
    retry: shouldRetryAppViewRequest,
  });
  useFeedFirstContentTiming(paintKey, Boolean(query.data?.pages.some(page => page.entries.length)) && !query.isError, !query.isFetchedAfterMount);
  const { fetchNextPage } = query;

  useEffect(() => {
    const pages = query.data?.pages;
    if (!pages?.length) return;
    const urls = new Set<string>();
    for (const page of pages) {
      for (const entry of page.entries) {
        const thumb = entry.thumbnailUrl?.trim();
        if (thumb) urls.add(thumb);
      }
    }
    prefetchCachedImages(urls);
  }, [query.data]);

  useEffect(() => {
    if (
      dummyReaderDataEnabled ||
      !query.isSuccess ||
      query.isPlaceholderData ||
      !normalizedKey ||
      !viewerDid
    ) return;
    if (telemetryKeyRef.current === paintKey) return;
    telemetryKeyRef.current = paintKey;
    const oauth = getOAuthSession();
    if (!oauth) return;
    const cacheHit = !query.isFetchedAfterMount;
    const durationMs = performance.now() - paintStartedRef.current;
    void recordClientPerformance(oauth, {
      event: cacheHit ? "cached_feed_paint" : "uncached_feed_paint",
      durationMs,
      feedType: "publication",
      cacheState: cacheHit ? "hit" : "miss",
      outcome: "success",
    }).catch(() => undefined);
    void recordClientPerformance(oauth, {
      event: "feed_switch",
      durationMs,
      feedType: "publication",
      cacheState: cacheHit ? "hit" : "miss",
      outcome: "success",
    }).catch(() => undefined);
  }, [
    getOAuthSession,
    dummyReaderDataEnabled,
    normalizedKey,
    paintKey,
    query.isFetchedAfterMount,
    query.isPlaceholderData,
    query.isSuccess,
    viewerDid,
  ]);

  useEffect(() => {
    if (!query.isError || !normalizedKey || !viewerDid) return;
    if (errorTelemetryKeyRef.current === paintKey) return;
    errorTelemetryKeyRef.current = paintKey;
    const oauth = getOAuthSession();
    if (!oauth) return;
    void recordClientPerformance(oauth, {
      event: "feed_error",
      durationMs: performance.now() - paintStartedRef.current,
      feedType: "publication",
      cacheState: query.data?.pages.length ? "hit" : "miss",
      outcome: "error",
    }).catch(() => undefined);
  }, [getOAuthSession, normalizedKey, paintKey, query.data?.pages.length, query.isError, viewerDid]);

  const publicationFeed = useMemo<AggregateAppViewFeed | null>(
    () => normalizedKey ? { kind: "publication", id: normalizedKey } : null,
    [normalizedKey],
  );
  const refetch = useGuardedFeedRefresh({
    queryKey: entriesQueryKey,
    feed: publicationFeed,
    articleFilter,
    enabled: !dummyReaderDataEnabled && !!session && !!normalizedKey,
    hasData: !!query.data?.pages.length && !query.isPlaceholderData,
    isFetchedAfterMount: query.isFetchedAfterMount,
    oauthSessionReloadSeq,
    getOAuthSession,
    fetchInitial: query.refetch,
  });

  useEffect(() => {
    const pageCount = query.data?.pages.length ?? 0;
    if (
      articleFilter !== "all" ||
      query.isPlaceholderData ||
      pageCount === 0 ||
      pageCount >= 3 ||
      !query.hasNextPage ||
      query.isFetchingNextPage
    ) {
      return;
    }
    // Let active first-page requests and images finish before bounded prefetch.
    const handle = globalThis.setTimeout(() => {
      if (document.visibilityState === "visible") void fetchNextPage();
    }, 8_000);
    return () => globalThis.clearTimeout(handle);
  }, [
    articleFilter,
    query.data?.pages.length,
    fetchNextPage,
    query.hasNextPage,
    query.isFetchingNextPage,
    query.isPlaceholderData,
  ]);

  return { ...query, refetch, scopePending: false };
}

export function useAggregateFeedEntries(
  feed: AggregateAppViewFeed | null,
  articleFilter: ArticleListFilter = "all",
) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const dummyReaderDataEnabled = isDummyReaderDataEnabled();
  const viewerDid = session?.did ?? "";
  const queryClient = useQueryClient();
  const feedKind = feed?.kind ?? "";
  const feedId = feed?.id ?? "";
  const aggregateQueryKey = useMemo(
    () =>
      ["aggregateEntries", viewerDid, feedKind, feedId, articleFilter] as const,
    [articleFilter, feedId, feedKind, viewerDid]
  );
  const paintStartedRef = useRef(0);
  const telemetryKeyRef = useRef<string | null>(null);
  const errorTelemetryKeyRef = useRef<string | null>(null);
  const paintKey = `${viewerDid}:${feedKind}:${feedId}:${articleFilter}`;
  useEffect(() => {
    paintStartedRef.current = performance.now();
  }, [paintKey]);
  const query = useInfiniteQuery({
    queryKey: aggregateQueryKey,
    queryFn: async ({ pageParam, signal }) => {
      if (!feed) return { entries: [], cursor: undefined };
      if (dummyReaderDataEnabled) {
        return {
          entries: dummyEntriesForAggregateFeed(feed),
          cursor: undefined,
        };
      }
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const fetchPage = () => listAggregateFeedFromAppView({
        feed,
        cursor: pageParam,
        filter: articleFilter,
        oauthSession: oauth,
        signal,
      });
      const assertCurrent = captureFeedRequestGuard(queryClient, aggregateQueryKey, oauth, getOAuthSession, signal);
      const page = await (pageParam ? fetchPage() : coalesceFeedFirstPage(queryClient, oauth, aggregateQueryKey, fetchPage, signal));
      assertCurrent();
      // A successful first page means the server has prepared list publication metadata.
      if (feed.kind === "list" && !pageParam && !signal.aborted && getOAuthSession() === oauth) {
        const resolvedListQuery = {
          queryKey: ["standardReaderList", viewerDid, oauthSessionReloadSeq, feedId],
          exact: true,
        };
        // Replace any earlier resolution still in flight with the prepared server metadata.
        void queryClient.cancelQueries(resolvedListQuery).then(() => {
          if (!signal.aborted && getOAuthSession() === oauth) {
            return queryClient.invalidateQueries(resolvedListQuery);
          }
        });
      }
      return page;
    },
    initialPageParam: undefined as string | undefined,
    initialData:
      dummyReaderDataEnabled && feed
        ? {
            pages: [
              {
                entries: dummyEntriesForAggregateFeed(feed),
                cursor: undefined,
              },
            ],
            pageParams: [undefined],
          }
        : undefined,
    placeholderData:
      articleFilter === "unread" && feed
        ? () =>
            unreadFeedPlaceholder(
              queryClient.getQueryData<
                InfiniteData<EntriesPage, string | undefined>
              >([
                ...AGGREGATE_ENTRIES_QUERY_KEY(viewerDid, feed),
                "all",
              ])
            )
        : undefined,
    getNextPageParam: entriesNextPageParam,
    enabled: !!feed && !!session,
    staleTime: ENTRIES_QUERY_STALE_MS,
    refetchOnMount: false,
    refetchOnReconnect: false,
    refetchOnWindowFocus: false,
    gcTime: 1000 * 60 * 60 * 24,
    retry: shouldRetryAppViewRequest,
  });
  useFeedFirstContentTiming(paintKey, Boolean(query.data?.pages.some(page => page.entries.length)) && !query.isError, !query.isFetchedAfterMount);
  const { fetchNextPage } = query;

  useEffect(() => {
    if (
      dummyReaderDataEnabled ||
      !query.isSuccess ||
      query.isPlaceholderData ||
      !feed ||
      !viewerDid
    ) return;
    if (telemetryKeyRef.current === paintKey) return;
    telemetryKeyRef.current = paintKey;
    const oauth = getOAuthSession();
    if (!oauth) return;
    const cacheHit = !query.isFetchedAfterMount;
    void recordClientPerformance(oauth, {
      event: cacheHit ? "cached_feed_paint" : "uncached_feed_paint",
      durationMs: performance.now() - paintStartedRef.current,
      feedType: "aggregate",
      cacheState: cacheHit ? "hit" : "miss",
      outcome: "success",
    }).catch(() => undefined);
    void recordClientPerformance(oauth, {
      event: "feed_switch",
      durationMs: performance.now() - paintStartedRef.current,
      feedType: "aggregate",
      cacheState: cacheHit ? "hit" : "miss",
      outcome: "success",
    }).catch(() => undefined);
  }, [
    feed,
    getOAuthSession,
    dummyReaderDataEnabled,
    paintKey,
    query.isFetchedAfterMount,
    query.isPlaceholderData,
    query.isSuccess,
    viewerDid,
  ]);

  useEffect(() => {
    if (!query.isError || !feed || !viewerDid) return;
    if (errorTelemetryKeyRef.current === paintKey) return;
    errorTelemetryKeyRef.current = paintKey;
    const oauth = getOAuthSession();
    if (!oauth) return;
    void recordClientPerformance(oauth, {
      event: "feed_error",
      durationMs: performance.now() - paintStartedRef.current,
      feedType: "aggregate",
      cacheState: query.data?.pages.length ? "hit" : "miss",
      outcome: "error",
    }).catch(() => undefined);
  }, [feed, getOAuthSession, paintKey, query.data?.pages.length, query.isError, viewerDid]);

  const refreshFeed = useMemo<AggregateAppViewFeed | null>(
    () => feedKind ? { kind: feedKind as AggregateAppViewFeed["kind"], ...(feedId ? { id: feedId } : {}) } : null,
    [feedId, feedKind],
  );
  const refetch = useGuardedFeedRefresh({
    queryKey: aggregateQueryKey,
    feed: refreshFeed,
    articleFilter,
    enabled: !dummyReaderDataEnabled && !!session && !!feed,
    hasData: !!query.data?.pages.length && !query.isPlaceholderData,
    isFetchedAfterMount: query.isFetchedAfterMount,
    oauthSessionReloadSeq,
    getOAuthSession,
    fetchInitial: query.refetch,
  });

  useEffect(() => {
    const pageCount = query.data?.pages.length ?? 0;
    if (
      articleFilter !== "all" ||
      query.isPlaceholderData ||
      pageCount === 0 ||
      pageCount >= 3 ||
      !query.hasNextPage ||
      query.isFetchingNextPage
    ) {
      return;
    }
    // Let active first-page requests and images finish before bounded prefetch.
    const handle = globalThis.setTimeout(() => {
      if (document.visibilityState === "visible") void fetchNextPage();
    }, 8_000);
    return () => globalThis.clearTimeout(handle);
  }, [
    articleFilter,
    query.data?.pages.length,
    fetchNextPage,
    query.hasNextPage,
    query.isFetchingNextPage,
    query.isPlaceholderData,
  ]);

  return { ...query, refetch: async () => { await refetch(); } };
}

/**
 * Returns entry detail from `app.thesocialwire.appview.getEntry`.
 */
export function useEntry(entryId: string | null) {
  const { session, getOAuthSession } = useAuth();
  const dummyReaderDataEnabled = isDummyReaderDataEnabled();
  const normalizedId = entryId ? normalizeAtRepoParam(entryId) : null;

  return useQuery({
    queryKey: ENTRY_DETAIL_QUERY_KEY(normalizedId ?? ""),
    queryFn: async ({ signal }) => {
      if (!normalizedId) return null;
      if (dummyReaderDataEnabled) {
        return dummyEntryDetail(normalizedId);
      }
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      if (!isThinAppViewEnabled()) {
        throw new Error("Thin AppView is required for entry detail");
      }
      const appViewEntry = await getEntryFromAppView(oauth, normalizedId, signal);
      if (
        appViewEntry &&
        !appViewEntry.embedUrl &&
        !appViewEntry.originalUrl &&
        isStandardSiteEntryId(normalizedId)
      ) {
        const directUrl = await resolveEntryOpenUrlFromPds(normalizedId, oauth);
        if (directUrl) {
          return {
            ...appViewEntry,
            originalUrl: appViewEntry.originalUrl ?? directUrl,
            embedUrl: directUrl,
          };
        }
      }
      return appViewEntry;
    },
    enabled: !!normalizedId && !!session,
    staleTime: 5 * 60_000,
    refetchOnMount: false,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  });
}
