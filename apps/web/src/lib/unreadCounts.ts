import type { InfiniteData, QueryClient } from "@tanstack/react-query";

import { ENTRIES_QUERY_KEY, type EntriesPage } from "@/hooks/useEntries";
import {
  normalizeAtRepoParam,
  type EntryListItem,
} from "@/lib/atprotoClient";

/**
 * Flattens paginated entry list cache into a single list (may contain duplicates
 * across pages if the cache merged oddly).
 */
export function flattenCachedInfiniteEntries(
  data: InfiniteData<EntriesPage> | undefined
): EntryListItem[] {
  if (!data?.pages?.length) return [];
  const out: EntryListItem[] = [];
  for (const page of data.pages) {
    out.push(...page.entries);
  }
  return out;
}

/**
 * Counts distinct entries that are not yet read. Duplicates by `entryId` are ignored.
 */
export function countUnreadCachedEntries(
  entries: EntryListItem[],
  isEntryRead: (entryId: string) => boolean
): number {
  const seen = new Set<string>();
  let count = 0;
  for (const entry of entries) {
    if (seen.has(entry.entryId)) continue;
    seen.add(entry.entryId);
    if (!isEntryRead(entry.entryId)) count += 1;
  }
  return count;
}

/**
 * Counts distinct entries already marked read in the local read map.
 */
export function countCachedReadEntries(
  entries: EntryListItem[],
  isEntryRead: (entryId: string) => boolean
): number {
  const seen = new Set<string>();
  let count = 0;
  for (const entry of entries) {
    if (seen.has(entry.entryId)) continue;
    seen.add(entry.entryId);
    if (isEntryRead(entry.entryId)) count += 1;
  }
  return count;
}

export type EffectivePublicationUnreadCountOptions = {
  /**
   * When true, an AppView baseline is never exceeded by partial first-page cache
   * (sidebar prefetch). Local read marks can still lower the badge.
   */
  capRaiseToServerCount?: boolean;
};

/**
 * Merges AppView unread baseline with local read state for cached feed rows.
 */
export function effectivePublicationUnreadCount(
  serverCount: number,
  queryClient: QueryClient,
  viewerDid: string,
  publicationId: string,
  isEntryRead: (entryId: string) => boolean,
  options?: EffectivePublicationUnreadCountOptions
): number {
  const cached = getCachedEntriesForPublication(queryClient, viewerDid, publicationId);
  if (cached.length === 0) return serverCount;

  const cachedUnread = countUnreadCachedEntries(cached, isEntryRead);
  const cachedRead = countCachedReadEntries(cached, isEntryRead);
  const reconciled = Math.max(cachedUnread, serverCount - cachedRead);
  if (options?.capRaiseToServerCount && serverCount > 0) {
    return Math.min(reconciled, serverCount);
  }
  return reconciled;
}

export function findUnreadCountInMap(
  publicationUnreadCounts: Map<string, number>,
  publicationId: string
): number | undefined {
  const target = normalizeAtRepoParam(publicationId);
  for (const [key, count] of publicationUnreadCounts) {
    if (normalizeAtRepoParam(key) === target) return count;
  }
  return publicationUnreadCounts.get(publicationId);
}

/**
 * Sums per-publication unread totals for a list of publications (e.g. one folder).
 */
export function lookupUnreadCountInMap(
  publicationUnreadCounts: Map<string, number>,
  publicationId: string
): number {
  return findUnreadCountInMap(publicationUnreadCounts, publicationId) ?? 0;
}

export function sumUnreadForPublications(
  publications: Array<{ publicationId: string }>,
  publicationUnreadCounts: Map<string, number>
): number {
  let sum = 0;
  const seen = new Set<string>();
  for (const pub of publications) {
    const key = normalizeAtRepoParam(pub.publicationId);
    if (seen.has(key)) continue;
    seen.add(key);
    sum += lookupUnreadCountInMap(publicationUnreadCounts, pub.publicationId);
  }
  return sum;
}

/** True when the entry (or any row) is present in the TanStack entries cache. */
export function publicationEntryIsCached(
  queryClient: QueryClient,
  viewerDid: string,
  publicationId: string,
  entryId: string
): boolean {
  return getCachedEntriesForPublication(queryClient, viewerDid, publicationId).some(
    (entry) => entry.entryId === entryId
  );
}

/** Cached entry rows for a publication (any article-list filter variant). */
export function getCachedEntriesForPublication(
  queryClient: QueryClient,
  viewerDid: string,
  publicationId: string
): EntryListItem[] {
  const normalized = normalizeAtRepoParam(publicationId);
  const publicationQueries = queryClient.getQueriesData<InfiniteData<EntriesPage>>({
    queryKey: ENTRIES_QUERY_KEY(viewerDid, normalized),
  });
  const aggregateQueries = queryClient.getQueriesData<InfiniteData<EntriesPage>>({
    queryKey: ["aggregateEntries", viewerDid],
  });
  const seen = new Set<string>();
  const out: EntryListItem[] = [];
  for (const [, data] of publicationQueries) {
    for (const entry of flattenCachedInfiniteEntries(data)) {
      if (seen.has(entry.entryId)) continue;
      seen.add(entry.entryId);
      out.push(entry);
    }
  }
  for (const [, data] of aggregateQueries) {
    for (const entry of flattenCachedInfiniteEntries(data)) {
      if (
        !entry.publicationId ||
        normalizeAtRepoParam(entry.publicationId) !== normalized ||
        seen.has(entry.entryId)
      ) {
        continue;
      }
      seen.add(entry.entryId);
      out.push(entry);
    }
  }
  return out;
}

/**
 * Distinct entry AT-URIs present in the TanStack infinite-query cache for the given publications.
 */
export function distinctCachedEntryIdsForPublications(
  queryClient: QueryClient,
  viewerDid: string,
  publications: Array<{ publicationId: string }>
): string[] {
  const seen = new Set<string>();
  for (const pub of publications) {
    for (const entry of getCachedEntriesForPublication(
      queryClient,
      viewerDid,
      pub.publicationId
    )) {
      seen.add(entry.entryId);
    }
  }
  return [...seen];
}
