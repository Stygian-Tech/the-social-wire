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
