import type { InfiniteData, Query } from "@tanstack/react-query";

type EntryListPage = { entries: unknown[]; cursor?: string };

/** Persist bounded successful feeds, requiring a viewer key for private feeds. */
export function shouldPersistEntriesQuery(query: {
  queryKey: Query["queryKey"];
  state: Pick<Query["state"], "status" | "data">;
}): boolean {
  const key = query.queryKey;
  if (!Array.isArray(key) || query.state.status !== "success") return false;

  const isPublicFeed = key[0] === "wireEntries" || key[0] === "wireEditionMore";
  const isViewerFeed = key[0] === "entries" || key[0] === "aggregateEntries";
  if (!isPublicFeed && !isViewerFeed) return false;
  if (isViewerFeed && (typeof key[1] !== "string" || key[1].length === 0)) return false;

  const data = query.state.data as InfiniteData<EntryListPage> | undefined;
  if (!data?.pages?.length || data.pages.length > 3) return false;
  const totalEntries = data.pages.reduce((count, page) => count + (page.entries?.length ?? 0), 0);
  return totalEntries <= 150;
}
