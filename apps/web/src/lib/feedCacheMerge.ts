import type { InfiniteData } from "@tanstack/react-query";

import type { EntriesPage } from "@/hooks/useEntries";
import { dedupeEntryListItems } from "@/lib/rssFeedCore";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";

/** Merge a fresh first page without dropping cached tail pages or their page params. */
export function mergeFeedFirstPageRefresh(
  existing: InfiniteData<EntriesPage> | undefined,
  freshPage: EntriesPage
): InfiniteData<EntriesPage> {
  if (!existing?.pages.length) {
    return { pages: [freshPage], pageParams: [undefined] };
  }

  const [firstPage, ...restPages] = existing.pages;
  const [firstParam, ...restParams] = existing.pageParams;
  const freshIds = new Set(freshPage.entries.map((entry) => entry.entryId));
  const carryOver = firstPage.entries.filter(
    (entry) => !freshIds.has(entry.entryId)
  );
  const mergedFirstPageEntries = dedupeEntryListItems([
    ...freshPage.entries,
    ...carryOver,
  ]);
  const seenEntryIds = new Set(
    mergedFirstPageEntries.map((entry) => entry.entryId)
  );
  const dedupedRestPages = restPages.map((page) => ({
    ...page,
    entries: page.entries.filter((entry) => {
      if (seenEntryIds.has(entry.entryId)) return false;
      seenEntryIds.add(entry.entryId);
      return true;
    }),
  }));

  return {
    pages: [
      {
        entries: mergedFirstPageEntries,
        cursor: freshPage.cursor ?? firstPage.cursor,
      },
      ...dedupedRestPages,
    ],
    pageParams: [firstParam, ...restParams],
  };
}

/** Seed an unread query from already-painted All rows while its server page loads. */
export function unreadFeedPlaceholder(
  allFeed: InfiniteData<EntriesPage, string | undefined> | undefined
): InfiniteData<EntriesPage, string | undefined> | undefined {
  if (!allFeed?.pages.length) return undefined;
  const entries = dedupeEntryListItems(
    allFeed.pages.flatMap((page) => page.entries)
  ).filter((entry) => !entry.isRead);
  if (entries.length === 0) return undefined;
  return {
    pages: [{ entries, cursor: undefined }],
    pageParams: [undefined],
  };
}

/** Unread pages are authoritative snapshots; cached tail pages may now be read. */
export function mergeFeedRefreshForFilter(
  existing: InfiniteData<EntriesPage> | undefined,
  freshPage: EntriesPage,
  articleFilter: ArticleListFilter
): InfiniteData<EntriesPage> {
  if (articleFilter === "unread") {
    return { pages: [freshPage], pageParams: [undefined] };
  }
  return mergeFeedFirstPageRefresh(existing, freshPage);
}
