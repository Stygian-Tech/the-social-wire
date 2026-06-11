import { describe, expect, it } from "bun:test";

import type { InfiniteData } from "@tanstack/react-query";

import { ENTRIES_QUERY_KEY, type EntriesPage } from "@/hooks/useEntries";
import type { EntryListItem } from "@/lib/atprotoClient";
import {
  countUnreadCachedEntries,
  distinctCachedEntryIdsForPublications,
  effectivePublicationUnreadCount,
  flattenCachedInfiniteEntries,
  publicationEntryIsCached,
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
  it("returns distinct entry IDs across publications and filters", () => {
    const pubDid = "did:plc:alice";
    const otherDid = "did:plc:bob";
    const e1 = makeEntry("at://did/a/site.standard.entry/1");
    const e2 = makeEntry("at://did/a/site.standard.entry/2");
    const eDup = makeEntry("at://did/a/site.standard.entry/1");
    const store = new Map<string, InfiniteData<EntriesPage>>();
    store.set(JSON.stringify([...ENTRIES_QUERY_KEY(pubDid), "all"]), {
      pages: [{ entries: [e1, e2], cursor: undefined }],
      pageParams: [undefined],
    });
    store.set(JSON.stringify([...ENTRIES_QUERY_KEY(otherDid), "unread"]), {
      pages: [{ entries: [eDup], cursor: undefined }],
      pageParams: [undefined],
    });
    const queryClient = {
      getQueriesData: <T,>({ queryKey }: { queryKey: readonly unknown[] }) => {
        const prefix = JSON.stringify(queryKey).slice(0, -1);
        const out: [unknown, T][] = [];
        for (const [key, value] of store) {
          if (key.startsWith(prefix)) {
            out.push([JSON.parse(key), value as T]);
          }
        }
        return out;
      },
    } as unknown as import("@tanstack/react-query").QueryClient;
    const ids = distinctCachedEntryIdsForPublications(queryClient, [
      { publicationId: pubDid },
      { publicationId: otherDid },
    ]);
    expect(ids).toEqual([e1.entryId, e2.entryId]);
  });

  it("returns empty when cache is missing", () => {
    const queryClient = {
      getQueriesData: () => [],
    } as unknown as import("@tanstack/react-query").QueryClient;
    expect(
      distinctCachedEntryIdsForPublications(queryClient, [
        { publicationId: "did:plc:none" },
      ])
    ).toEqual([]);
  });
});

describe("effectivePublicationUnreadCount", () => {
  function mockQueryClientWithEntries(
    publicationId: string,
    entries: EntryListItem[]
  ) {
    const store = new Map<string, InfiniteData<EntriesPage>>();
    for (const filter of ["all", "unread"]) {
      store.set(JSON.stringify([...ENTRIES_QUERY_KEY(publicationId), filter]), {
        pages: [{ entries, cursor: undefined }],
        pageParams: [undefined],
      });
    }
    return {
      getQueriesData: <T,>({ queryKey }: { queryKey: readonly unknown[] }) => {
        const prefix = JSON.stringify(queryKey).slice(0, -1);
        const out: [unknown, T][] = [];
        for (const [key, value] of store) {
          if (key.startsWith(prefix)) {
            out.push([JSON.parse(key), value as T]);
          }
        }
        return out;
      },
    } as unknown as import("@tanstack/react-query").QueryClient;
  }

  it("lowers server count when cached entries are locally read", () => {
    const publicationId =
      "at://did:plc:author/site.standard.publication/main";
    const readId = "at://did:plc:author/site.standard.document/read";
    const unreadId = "at://did:plc:author/site.standard.document/unread";
    const queryClient = mockQueryClientWithEntries(publicationId, [
      makeEntry(readId),
      makeEntry(unreadId),
    ]);
    const isRead = (id: string) => id === readId;

    expect(
      effectivePublicationUnreadCount(5, queryClient, publicationId, isRead)
    ).toBe(4);
  });

  it("raises count when cache shows unread but server reports zero", () => {
    const publicationId =
      "at://did:plc:author/site.standard.publication/main";
    const unreadId = "at://did:plc:author/site.standard.document/unread";
    const queryClient = mockQueryClientWithEntries(publicationId, [
      makeEntry(unreadId),
    ]);

    expect(
      effectivePublicationUnreadCount(0, queryClient, publicationId, () => false)
    ).toBe(1);
  });

  it("does not raise above server baseline when capRaiseToServerCount is set", () => {
    const publicationId = "rss:https://example.com/feed.xml";
    const queryClient = mockQueryClientWithEntries(
      publicationId,
      Array.from({ length: 20 }, (_, i) =>
        makeEntry(`rssentry:https://example.com/post-${i}`)
      )
    );

    expect(
      effectivePublicationUnreadCount(3, queryClient, publicationId, () => false, {
        capRaiseToServerCount: true,
      })
    ).toBe(3);
  });

  it("still lowers server count when capRaiseToServerCount is set", () => {
    const publicationId =
      "at://did:plc:author/site.standard.publication/main";
    const readId = "at://did:plc:author/site.standard.document/read";
    const unreadId = "at://did:plc:author/site.standard.document/unread";
    const queryClient = mockQueryClientWithEntries(publicationId, [
      makeEntry(readId),
      makeEntry(unreadId),
    ]);
    const isRead = (id: string) => id === readId;

    expect(
      effectivePublicationUnreadCount(5, queryClient, publicationId, isRead, {
        capRaiseToServerCount: true,
      })
    ).toBe(4);
  });

  it("detects when an entry is present in the entries cache", () => {
    const publicationId =
      "at://did:plc:author/site.standard.publication/main";
    const entryId = "at://did:plc:author/site.standard.document/abc";
    const queryClient = mockQueryClientWithEntries(publicationId, [
      makeEntry(entryId),
    ]);

    expect(
      publicationEntryIsCached(queryClient, publicationId, entryId)
    ).toBe(true);
    expect(
      publicationEntryIsCached(
        queryClient,
        publicationId,
        "at://did:plc:author/site.standard.document/other"
      )
    ).toBe(false);
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
