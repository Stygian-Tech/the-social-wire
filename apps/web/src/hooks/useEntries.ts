"use client";

import { useEffect, useMemo, useRef } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
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
import { coalesceFeedFirstPage, getFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";
import { refreshPublicationFeedFirstPage } from "@/lib/feedRefresh";
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

/**
 * Returns a paginated list of entries for a publication sidebar selection.
 */
export function useEntries(
  publicationKey: string | null,
  articleFilter: ArticleListFilter = "all"
) {
  const { session, getOAuthSession } = useAuth();
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
  const refreshAndEnrollmentKeyRef = useRef<string | null>(null);
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
      return pageParam ? fetchPage() : coalesceFeedFirstPage(queryClient, oauth, entriesQueryKey, fetchPage);
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
    refetchOnMount: true,
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

  useEffect(() => {
    if (
      dummyReaderDataEnabled ||
      !query.isSuccess ||
      query.isPlaceholderData ||
      !normalizedKey ||
      !viewerDid
    ) {
      return;
    }
    const refreshKey = `${viewerDid}:${normalizedKey}:${articleFilter}`;
    if (refreshAndEnrollmentKeyRef.current === refreshKey) return;
    refreshAndEnrollmentKeyRef.current = refreshKey;
    const oauth = getOAuthSession();
    if (!oauth) return;

    const refreshRestoredCache = async () => {
      if (query.isFetchedAfterMount || Date.now() - (queryClient.getQueryState(entriesQueryKey)?.dataUpdatedAt ?? 0) < ENTRIES_QUERY_STALE_MS) return;
      const refreshStartedAt = performance.now();
      try {
        await refreshPublicationFeedFirstPage({ queryClient, publicationKey: normalizedKey, articleFilter, oauthSession: oauth, viewerDid });
        void recordClientPerformance(oauth, {
          event: "fresh_merge",
          durationMs: performance.now() - refreshStartedAt,
          feedType: "publication",
          cacheState: "hit",
          outcome: "success",
        }).catch(() => undefined);
      } catch {
        /* stale cache remains visible */
      }
    };
    // Ingestion belongs to bootstrap/server refresh. A mounted feed only refreshes
    // restored data; freshly fetched or streamed pages do not need another read.
    void refreshRestoredCache();
  }, [
    articleFilter,
    dummyReaderDataEnabled,
    entriesQueryKey,
    getOAuthSession,
    normalizedKey,
    query.isFetchedAfterMount,
    query.isPlaceholderData,
    query.isSuccess,
    queryClient,
    viewerDid,
  ]);

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

  return { ...query, refetch: async () => {
    const oauth = getOAuthSession();
    if (!oauth || !normalizedKey) return false;
    return refreshPublicationFeedFirstPage({ queryClient, publicationKey: normalizedKey, articleFilter, oauthSession: oauth, viewerDid, allowCacheMiss: true });
  }, scopePending: false };
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
  const restoredRefreshKeyRef = useRef<string | null>(null);
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
      const page = await (pageParam ? fetchPage() : coalesceFeedFirstPage(queryClient, oauth, aggregateQueryKey, fetchPage));
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
    refetchOnMount: true,
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

  useEffect(() => {
    if (
      dummyReaderDataEnabled ||
      !feed ||
      !viewerDid ||
      !query.data?.pages.length ||
      query.isPlaceholderData ||
      query.isFetchedAfterMount ||
      Date.now() - queryClient.getQueryState(aggregateQueryKey)!.dataUpdatedAt < ENTRIES_QUERY_STALE_MS
    ) {
      return;
    }
    const refreshKey = `${viewerDid}:${feed.kind}:${feed.id ?? ""}:${articleFilter}`;
    if (restoredRefreshKeyRef.current === refreshKey) return;
    restoredRefreshKeyRef.current = refreshKey;
    const oauth = getOAuthSession();
    if (!oauth) return;
    const refreshStartedAt = performance.now();
    const revision = getFeedRefreshRevision(queryClient, aggregateQueryKey);
    void coalesceFeedFirstPage(queryClient, oauth, aggregateQueryKey, () => listAggregateFeedFromAppView({
      feed,
      filter: articleFilter,
      oauthSession: oauth,
    }))
      .then((freshPage) => {
        if (getOAuthSession() !== oauth || getFeedRefreshRevision(queryClient, aggregateQueryKey) !== revision) return;
        queryClient.setQueryData<InfiniteData<EntriesPage>>(
          aggregateQueryKey,
          (current) => mergeFeedRefreshForFilter(current, freshPage, articleFilter)
        );
        void recordClientPerformance(oauth, {
          event: "fresh_merge",
          durationMs: performance.now() - refreshStartedAt,
          feedType: "aggregate",
          cacheState: "hit",
          outcome: "success",
        }).catch(() => undefined);
      })
      .catch(() => {
        /* stale cache remains visible */
      });
  }, [
    aggregateQueryKey,
    articleFilter,
    dummyReaderDataEnabled,
    feed,
    getOAuthSession,
    query.data?.pages.length,
    query.isFetchedAfterMount,
    query.isPlaceholderData,
    queryClient,
    viewerDid,
  ]);

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

  return { ...query, refetch: async () => {
    const oauth = getOAuthSession();
    if (!oauth || !feed) return;
    const revision = getFeedRefreshRevision(queryClient, aggregateQueryKey);
    const fresh = await coalesceFeedFirstPage(queryClient, oauth, aggregateQueryKey, () => listAggregateFeedFromAppView({ feed, filter: articleFilter, oauthSession: oauth }));
    if (getOAuthSession() !== oauth || getFeedRefreshRevision(queryClient, aggregateQueryKey) !== revision) return;
    queryClient.setQueryData<InfiniteData<EntriesPage>>(aggregateQueryKey, current => mergeFeedRefreshForFilter(current, fresh, articleFilter));
  } };
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
