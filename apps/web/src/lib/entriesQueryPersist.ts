import type { InfiniteData, Query } from "@tanstack/react-query";
import type { PersistedClient } from "@tanstack/react-query-persist-client";

type EntryListPage = { entries?: unknown[]; stories?: unknown[]; cursor?: string; moreCursor?: string };
const MAX_PERSISTED_PAGES = 3;
const MAX_PERSISTED_ROWS = 150;

/** Persist bounded successful feeds, requiring a viewer key for private feeds. */
export function shouldPersistEntriesQuery(query: {
  queryKey: Query["queryKey"];
  state: Pick<Query["state"], "status" | "data"> & { dataUpdatedAt?: number };
}): boolean {
  const key = query.queryKey;
  if (!Array.isArray(key) || (query.state.status !== "success" && !(query.state.status === "error" && (query.state.dataUpdatedAt ?? 0) > 0))) return false;

  const isPublicFeed = key[0] === "wireEntries" || key[0] === "wireEditionMore" || key[0] === "wireEdition";
  const isViewerFeed = key[0] === "entries" || key[0] === "aggregateEntries" || key[0] === "circleEdition";
  if (!isPublicFeed && !isViewerFeed) return false;
  if (isViewerFeed && (typeof key[1] !== "string" || !key[1].startsWith("did:"))) return false;

  const data = query.state.data as InfiniteData<EntryListPage> | undefined;
  const rowsKey = key[0] === "wireEdition" || key[0] === "circleEdition" ? "stories" : "entries";
  return Boolean(data?.pages?.length && Array.isArray(data.pageParams) && data.pages.every(page => Array.isArray(page?.[rowsKey])));
}

/** Bound the disk snapshot without evicting a feed after the user scrolls farther. */
export function prepareEntriesQueryPersistence(client: PersistedClient): PersistedClient {
  return { ...client, clientState: { ...client.clientState, queries: client.clientState.queries.map(query => {
    if (!shouldPersistEntriesQuery(query)) return query;
    const data = query.state.data as InfiniteData<EntryListPage>;
    const rowsKey = query.queryKey[0] === "wireEdition" || query.queryKey[0] === "circleEdition" ? "stories" : "entries";
    const pages: EntryListPage[] = [];
    let remaining = MAX_PERSISTED_ROWS;
    let truncatedPage = false;
    for (const page of data.pages.slice(0, MAX_PERSISTED_PAGES)) {
      const rows = page[rowsKey]!;
      if (rows.length > remaining) {
        if (pages.length === 0) {
          // No cursor identifies a position inside this page. Require a fresh
          // first-page read before continuing rather than skipping omitted rows.
          pages.push({ ...page, [rowsKey]: rows.slice(0, remaining), cursor: undefined, moreCursor: undefined });
          truncatedPage = true;
        }
        break;
      }
      pages.push(page);
      remaining -= rows.length;
      if (remaining === 0) break;
    }
    return { ...query, state: { ...query.state,
      data: { ...data, pages, pageParams: data.pageParams.slice(0, pages.length) },
      dataUpdatedAt: truncatedPage ? 1 : query.state.dataUpdatedAt,
      // A failed background check must not erase previously received content or
      // restore an error screen in place of that content on the next visit.
      status: "success" as const, error: null, fetchStatus: "idle" as const,
      fetchFailureCount: 0, fetchFailureReason: null,
    } };
  }) } };
}
