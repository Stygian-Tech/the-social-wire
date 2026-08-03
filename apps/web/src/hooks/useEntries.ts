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
import { getEntry, normalizeAtRepoParam, parseAtUri } from "@/lib/atprotoClient";
import type { EntryListItem, EntryDetail } from "@/lib/atprotoClient";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import { prefetchCachedImages } from "@/lib/imageBlobCache";
import { mergeFeedFirstPageRefresh } from "@/lib/feedCacheMerge";
import {
  getEntryFromAppView,
  enrollAuthorsInAppView,
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
import { normalizedFeedUrlFromRssPublicationId } from "@/lib/rssFeedCore";
import { recordClientPerformance } from "@/lib/clientPerformanceTelemetry";
import { useAuth } from "./useAuth";

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

const STANDARD_SITE_ENTRY_COLLECTIONS = new Set([
  "site.standard.document",
  "site.standard.entry",
  "com.standard.document",
  "com.standard.entry",
]);

function isStandardSiteEntryId(entryId: string): boolean {
  const parsed = parseAtUri(entryId);
  return parsed ? STANDARD_SITE_ENTRY_COLLECTIONS.has(parsed.collection) : false;
}

/** Stop pagination when the server returns an empty page without advancing the cursor. */
export function entriesNextPageParam(
  lastPage: EntriesPage,
  _allPages: EntriesPage[],
  lastPageParam: string | undefined
): string | undefined {
  const cursor = lastPage.cursor;
  if (!cursor) return undefined;
  if (lastPage.entries.length === 0 && lastPageParam === cursor) {
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
      return fetchEntriesInfinitePage({
        normalizedPublicationKey: normalizedKey,
        pageParam,
        signal,
        oauthSession: oauth,
        viewerDid,
        articleFilter,
        queryClient,
      });
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
    getNextPageParam: entriesNextPageParam,
    enabled:
      !!normalizedKey &&
      !!session &&
      !!viewerDid,
    staleTime: ENTRIES_QUERY_STALE_MS,
    refetchOnMount: false,
    refetchOnWindowFocus: false,
    gcTime: 1000 * 60 * 60 * 24,
    retry: shouldRetryAppViewRequest,
  });
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
    if (dummyReaderDataEnabled || !query.isSuccess || !normalizedKey || !viewerDid) return;
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

    const mergePage = (freshPage: EntriesPage) => {
      queryClient.setQueryData<InfiniteData<EntriesPage>>(
        entriesQueryKey,
        (current) => mergeFeedFirstPageRefresh(current, freshPage)
      );
    };
    const refreshRestoredCache = async () => {
      if (query.isFetchedAfterMount) return;
      const refreshStartedAt = performance.now();
      try {
        const freshPage = await listAggregateFeedFromAppView({
          feed: { kind: "publication", id: normalizedKey },
          filter: articleFilter,
          oauthSession: oauth,
        });
        mergePage(freshPage);
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
    const enrollAndMerge = async () => {
      const feedUrl = normalizedFeedUrlFromRssPublicationId(normalizedKey);
      const authorDid = parseAtUri(normalizedKey)?.did
        ?? (normalizedKey.startsWith("did:") ? normalizedKey : undefined);
      if (feedUrl) {
        await enrollAuthorsInAppView(oauth, [], [feedUrl]);
      } else if (authorDid) {
        await enrollAuthorsInAppView(oauth, [authorDid]);
      }
      const freshPage = await listAggregateFeedFromAppView({
        feed: { kind: "publication", id: normalizedKey },
        filter: articleFilter,
        oauthSession: oauth,
      });
      mergePage(freshPage);
    };
    void refreshRestoredCache()
      .then(enrollAndMerge)
      .catch(() => {
        /* enrollment and its post-index merge are best effort */
      });
  }, [
    articleFilter,
    dummyReaderDataEnabled,
    entriesQueryKey,
    getOAuthSession,
    normalizedKey,
    query.isFetchedAfterMount,
    query.isSuccess,
    queryClient,
    viewerDid,
  ]);

  useEffect(() => {
    const pageCount = query.data?.pages.length ?? 0;
    if (pageCount === 0 || pageCount >= 3 || !query.hasNextPage || query.isFetchingNextPage) {
      return;
    }
    const run = () => void fetchNextPage();
    if ("requestIdleCallback" in window) {
      const handle = window.requestIdleCallback(run, { timeout: 2_000 });
      return () => window.cancelIdleCallback(handle);
    }
    const handle = globalThis.setTimeout(run, 250);
    return () => globalThis.clearTimeout(handle);
  }, [
    query.data?.pages.length,
    fetchNextPage,
    query.hasNextPage,
    query.isFetchingNextPage,
  ]);

  return { ...query, scopePending: false };
}

export function useAggregateFeedEntries(
  feed: AggregateAppViewFeed | null,
  articleFilter: ArticleListFilter = "all",
) {
  const { session, getOAuthSession } = useAuth();
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
      return listAggregateFeedFromAppView({
        feed,
        cursor: pageParam,
        filter: articleFilter,
        oauthSession: oauth,
        signal,
      });
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
    getNextPageParam: entriesNextPageParam,
    enabled: !!feed && !!session,
    staleTime: ENTRIES_QUERY_STALE_MS,
    refetchOnMount: false,
    refetchOnWindowFocus: false,
    gcTime: 1000 * 60 * 60 * 24,
    retry: shouldRetryAppViewRequest,
  });
  const { fetchNextPage } = query;

  useEffect(() => {
    if (dummyReaderDataEnabled || !query.isSuccess || !feed || !viewerDid) return;
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
      query.isFetchedAfterMount
    ) {
      return;
    }
    const refreshKey = `${viewerDid}:${feed.kind}:${feed.id ?? ""}:${articleFilter}`;
    if (restoredRefreshKeyRef.current === refreshKey) return;
    restoredRefreshKeyRef.current = refreshKey;
    const oauth = getOAuthSession();
    if (!oauth) return;
    const refreshStartedAt = performance.now();
    void listAggregateFeedFromAppView({
      feed,
      filter: articleFilter,
      oauthSession: oauth,
    })
      .then((freshPage) => {
        queryClient.setQueryData<InfiniteData<EntriesPage>>(
          aggregateQueryKey,
          (current) => mergeFeedFirstPageRefresh(current, freshPage)
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
    queryClient,
    viewerDid,
  ]);

  useEffect(() => {
    const pageCount = query.data?.pages.length ?? 0;
    if (pageCount === 0 || pageCount >= 3 || !query.hasNextPage || query.isFetchingNextPage) {
      return;
    }
    const run = () => void fetchNextPage();
    if ("requestIdleCallback" in window) {
      const handle = window.requestIdleCallback(run, { timeout: 2_000 });
      return () => window.cancelIdleCallback(handle);
    }
    const handle = globalThis.setTimeout(run, 250);
    return () => globalThis.clearTimeout(handle);
  }, [
    query.data?.pages.length,
    fetchNextPage,
    query.hasNextPage,
    query.isFetchingNextPage,
  ]);

  return query;
}

/**
 * Returns entry detail from Thin AppView (`GET /v1/appview/entry`).
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
        const directEntry = await getEntry(normalizedId, oauth);
        if (directEntry?.embedUrl || directEntry?.originalUrl) {
          return {
            ...appViewEntry,
            originalUrl: directEntry.originalUrl ?? appViewEntry.originalUrl,
            embedUrl: directEntry.embedUrl ?? directEntry.originalUrl,
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
