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
 * Sums per-publication unread totals for a list of publications (e.g. one folder).
 */
export function sumUnreadForPublications(
  publications: Array<{ publicationId: string }>,
  publicationUnreadCounts: Map<string, number>
): number {
  let sum = 0;
  for (const pub of publications) {
    sum += publicationUnreadCounts.get(pub.publicationId) ?? 0;
  }
  return sum;
}

/**
 * Distinct entry AT-URIs present in the TanStack infinite-query cache for the given publications.
 */
export function distinctCachedEntryIdsForPublications(
  queryClient: Pick<QueryClient, "getQueryData">,
  publications: Array<{ publicationId: string }>
): string[] {
  const seen = new Set<string>();
  for (const pub of publications) {
    const normalized = normalizeAtRepoParam(pub.publicationId);
    const data = queryClient.getQueryData<InfiniteData<EntriesPage>>(
      ENTRIES_QUERY_KEY(normalized)
    );
    const entries = flattenCachedInfiniteEntries(data);
    for (const e of entries) {
      seen.add(e.entryId);
    }
  }
  return [...seen];
}
