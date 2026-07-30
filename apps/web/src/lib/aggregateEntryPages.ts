import type { EntriesPage, EntryListItem } from "@/hooks/useEntries";
import { dedupeIdentityKeys } from "@/lib/rssFeedCore";

export type AggregateEntryPageAccumulator = {
  pageRefs: readonly EntriesPage[];
  entries: EntryListItem[];
  seenEntryIds: Set<string>;
  seenIdentityKeys: Set<string>;
  seenTitlePublished: Set<string>;
  duplicatesSuppressed: number;
  mergeDurationMs: number;
};

const accumulatorByLastPage = new WeakMap<
  EntriesPage,
  AggregateEntryPageAccumulator
>();

function emptyAccumulator(): AggregateEntryPageAccumulator {
  return {
    pageRefs: [],
    entries: [],
    seenEntryIds: new Set(),
    seenIdentityKeys: new Set(),
    seenTitlePublished: new Set(),
    duplicatesSuppressed: 0,
    mergeDurationMs: 0,
  };
}

function hasStablePagePrefix(
  pages: readonly EntriesPage[],
  previous: AggregateEntryPageAccumulator,
): boolean {
  if (pages.length < previous.pageRefs.length) return false;
  return previous.pageRefs.every((page, index) => pages[index] === page);
}

export function mergeAggregateEntryPages(
  pages: readonly EntriesPage[],
  previous?: AggregateEntryPageAccumulator,
): AggregateEntryPageAccumulator {
  const startedAt = globalThis.performance?.now() ?? 0;
  const canAppend = previous != null && hasStablePagePrefix(pages, previous);
  const base = canAppend ? previous : emptyAccumulator();
  if (canAppend && pages.length === base.pageRefs.length) return base;

  const entries = [...base.entries];
  const seenEntryIds = new Set(base.seenEntryIds);
  const seenIdentityKeys = new Set(base.seenIdentityKeys);
  const seenTitlePublished = new Set(base.seenTitlePublished);
  let duplicatesSuppressed = base.duplicatesSuppressed;

  for (const page of pages.slice(base.pageRefs.length)) {
    for (const entry of page.entries) {
      if (seenEntryIds.has(entry.entryId)) {
        duplicatesSuppressed += 1;
        continue;
      }
      seenEntryIds.add(entry.entryId);

      const identityKeys = dedupeIdentityKeys({
        ...entry,
        articleUrl: entry.originalUrl,
      });
      if (identityKeys.size > 0) {
        if ([...identityKeys].some((key) => seenIdentityKeys.has(key))) {
          duplicatesSuppressed += 1;
          continue;
        }
        for (const key of identityKeys) seenIdentityKeys.add(key);
      } else {
        const titlePublished = `${entry.title.trim().toLowerCase()}|${entry.publishedAt}`;
        if (seenTitlePublished.has(titlePublished)) {
          duplicatesSuppressed += 1;
          continue;
        }
        seenTitlePublished.add(titlePublished);
      }

      entries.push(entry);
    }
  }

  return {
    pageRefs: pages,
    entries,
    seenEntryIds,
    seenIdentityKeys,
    seenTitlePublished,
    duplicatesSuppressed,
    mergeDurationMs: (globalThis.performance?.now() ?? startedAt) - startedAt,
  };
}

export function mergeAggregateEntryPagesCached(
  pages: readonly EntriesPage[],
): AggregateEntryPageAccumulator {
  if (pages.length === 0) return emptyAccumulator();

  let previous: AggregateEntryPageAccumulator | undefined;
  for (let index = pages.length - 1; index >= 0; index -= 1) {
    const cached = accumulatorByLastPage.get(pages[index]);
    if (
      cached &&
      cached.pageRefs.length === index + 1 &&
      cached.pageRefs.every((page, pageIndex) => pages[pageIndex] === page)
    ) {
      previous = cached;
      break;
    }
  }

  const result = mergeAggregateEntryPages(pages, previous);
  accumulatorByLastPage.set(pages[pages.length - 1], result);
  return result;
}
