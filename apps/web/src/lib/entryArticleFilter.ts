import type { EntryListItem } from "@/lib/atprotoClient";

export type ArticleListFilter = "all" | "unread";

/**
 * Filters the entry list for the Articles column. When `effectiveFilter` is
 * `"unread"`, entries already marked read are excluded.
 */
export function filterEntriesForArticleFilter(
  entries: EntryListItem[],
  effectiveFilter: ArticleListFilter,
  isEntryRead: (entryId: string) => boolean
): EntryListItem[] {
  if (effectiveFilter !== "unread") return entries;
  return entries.filter((e) => !isEntryRead(e.entryId));
}

/**
 * Whether the Articles column may claim there is nothing unread.
 *
 * Only true once pagination is exhausted. While pages are still arriving the
 * list keeps rendering (streaming each unread entry in as it is found, with a
 * footer loader) rather than blocking on a skeleton or prematurely showing an
 * empty state — a large backlog of read articles would otherwise leave the
 * column empty until the entire feed had been scanned.
 */
export function shouldShowNoUnreadEntriesState(args: {
  effectiveFilter: ArticleListFilter;
  visibleEntryCount: number;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
}): boolean {
  return (
    args.effectiveFilter === "unread" &&
    args.visibleEntryCount === 0 &&
    !args.hasNextPage &&
    !args.isFetchingNextPage
  );
}
