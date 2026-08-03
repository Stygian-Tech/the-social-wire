import { describe, expect, it } from "bun:test";

import {
  mergeAggregateEntryPages,
  mergeAggregateEntryPagesCached,
  type AggregateEntryPageAccumulator,
} from "@/lib/aggregateEntryPages";
import type { EntriesPage, EntryListItem } from "@/hooks/useEntries";

function entry(id: string, originalUrl?: string): EntryListItem {
  return {
    entryId: `at://did:plc:author/site.standard.document/${id}`,
    title: `Entry ${id}`,
    publishedAt: `2026-01-01T00:00:0${id}.000Z`,
    originalUrl,
  };
}

describe("mergeAggregateEntryPages", () => {
  it("processes appended pages while preserving existing entry identity", () => {
    const firstPage: EntriesPage = {
      entries: [entry("2"), entry("1")],
      cursor: "cursor-1",
    };
    const first = mergeAggregateEntryPages([firstPage]);
    const originalFirstEntry = first.entries[0];
    const secondPage: EntriesPage = {
      entries: [entry("0")],
      cursor: undefined,
    };

    const second = mergeAggregateEntryPages([firstPage, secondPage], first);

    expect(second.entries.map((item) => item.entryId)).toHaveLength(3);
    expect(second.entries[0]).toBe(originalFirstEntry);
    expect(second.pageRefs[0]).toBe(firstPage);
  });

  it("suppresses entry and canonical URL duplicates across page boundaries", () => {
    const duplicateId = entry("2");
    const first = mergeAggregateEntryPages([
      {
        entries: [
          duplicateId,
          entry("1", "https://example.com/article?source=first"),
        ],
      },
    ]);
    const second = mergeAggregateEntryPages(
      [
        first.pageRefs[0]!,
        {
          entries: [
            duplicateId,
            entry("0", "https://example.com/article?source=second"),
          ],
        },
      ],
      first,
    );

    expect(second.entries).toHaveLength(2);
    expect(second.duplicatesSuppressed).toBe(2);
  });

  it("rebuilds when an earlier query page is replaced", () => {
    const firstPage = { entries: [entry("1")] };
    const first = mergeAggregateEntryPages([firstPage]);
    const replacedPage = { entries: [entry("2")] };

    const rebuilt = mergeAggregateEntryPages(
      [replacedPage],
      first as AggregateEntryPageAccumulator,
    );

    expect(rebuilt.entries.map((item) => item.entryId)).toEqual([
      entry("2").entryId,
    ]);
  });

  it("uses cached prefixes while preserving prior row identity", () => {
    const firstEntry = entry("1");
    const secondEntry = entry("2");
    const firstPage: EntriesPage = {
      entries: [firstEntry],
      cursor: "cursor-1",
    };
    const secondPage: EntriesPage = { entries: [secondEntry] };

    const initial = mergeAggregateEntryPagesCached([firstPage]);
    const appended = mergeAggregateEntryPagesCached([firstPage, secondPage]);

    expect(appended.entries[0]).toBe(initial.entries[0]);
    expect(appended.entries[1]).toBe(secondEntry);
  });
});
