import { describe, expect, it } from "bun:test";

import type { InfiniteData } from "@tanstack/react-query";

import { ENTRIES_QUERY_KEY, type EntriesPage } from "@/hooks/useEntries";
import type { EntryListItem } from "@/lib/atprotoClient";
import {
  countUnreadCachedEntries,
  distinctCachedEntryIdsForPublications,
  flattenCachedInfiniteEntries,
  sumUnreadForPublications,
} from "@/lib/unreadCounts";

const makeEntry = (entryId: string): EntryListItem => ({
  entryId,
  title: "T",
  publishedAt: "2026-01-01T00:00:00.000Z",
});

describe("flattenCachedInfiniteEntries", () => {
  it("returns empty for undefined or empty pages", () => {
    expect(flattenCachedInfiniteEntries(undefined)).toEqual([]);
    expect(
      flattenCachedInfiniteEntries({
        pages: [],
        pageParams: [],
      } as InfiniteData<EntriesPage>)
    ).toEqual([]);
  });

  it("concatenates all pages", () => {
    const a = makeEntry("at://did/a/x/1");
    const b = makeEntry("at://did/a/x/2");
    const data: InfiniteData<EntriesPage> = {
      pages: [
        { entries: [a], cursor: "c1" },
        { entries: [b], cursor: undefined },
      ],
      pageParams: [undefined, "c1"],
    };
    expect(flattenCachedInfiniteEntries(data)).toEqual([a, b]);
  });
});

describe("countUnreadCachedEntries", () => {
  it("counts only unread and deduplicates by entryId", () => {
    const a = makeEntry("at://did/a/x/1");
    const b = makeEntry("at://did/a/x/2");
    const isRead = (id: string) => id === a.entryId;
    expect(
      countUnreadCachedEntries([a, b, a, b], isRead)
    ).toBe(1);
  });

  it("returns zero when all read", () => {
    const a = makeEntry("at://did/a/x/1");
    expect(countUnreadCachedEntries([a], () => true)).toBe(0);
  });
});

describe("distinctCachedEntryIdsForPublications", () => {
  it("returns distinct entry IDs across publications", () => {
    const pubDid = "did:plc:alice";
    const otherDid = "did:plc:bob";
    const e1 = makeEntry("at://did/a/site.standard.entry/1");
    const e2 = makeEntry("at://did/a/site.standard.entry/2");
    const eDup = makeEntry("at://did/a/site.standard.entry/1");
    const store = new Map<string, unknown>();
    store.set(JSON.stringify(ENTRIES_QUERY_KEY(pubDid)), {
      pages: [{ entries: [e1, e2], cursor: undefined }],
      pageParams: [undefined],
    } satisfies InfiniteData<EntriesPage>);
    store.set(JSON.stringify(ENTRIES_QUERY_KEY(otherDid)), {
      pages: [{ entries: [eDup], cursor: undefined }],
      pageParams: [undefined],
    } satisfies InfiniteData<EntriesPage>);
    const queryClient = {
      getQueryData: <T>(key: readonly unknown[]) =>
        store.get(JSON.stringify(key)) as T | undefined,
    };
    const ids = distinctCachedEntryIdsForPublications(queryClient, [
      { publicationId: pubDid },
      { publicationId: otherDid },
    ]);
    expect(ids).toEqual([e1.entryId, e2.entryId]);
  });

  it("returns empty when cache is missing", () => {
    const queryClient = {
      getQueryData: () => undefined,
    };
    expect(
      distinctCachedEntryIdsForPublications(queryClient, [
        { publicationId: "did:plc:none" },
      ])
    ).toEqual([]);
  });
});

describe("sumUnreadForPublications", () => {
  it("sums counts for listed publication IDs", () => {
    const counts = new Map<string, number>([
      ["pub-a", 2],
      ["pub-b", 3],
    ]);
    const sum = sumUnreadForPublications(
      [{ publicationId: "pub-a" }, { publicationId: "pub-b" }],
      counts
    );
    expect(sum).toBe(5);
  });

  it("treats missing map entries as zero", () => {
    const sum = sumUnreadForPublications(
      [{ publicationId: "unknown" }],
      new Map()
    );
    expect(sum).toBe(0);
  });
});
