import { describe, expect, it } from "bun:test";
import { QueryClient, type InfiniteData } from "@tanstack/react-query";

import {
  applySidebarPriorityEvent,
  applySidebarFoldersEvent,
  applySidebarSectionEvent,
  applyUnreadCountsEvent,
  writeStreamedEntriesPage,
} from "@/lib/bootstrapStreamState";
import { advanceFeedRefreshRevision, cancelViewerFeedRefreshes, captureFeedRefreshRevisions } from "@/lib/feedRefreshCoordinator";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { ENTRIES_QUERY_KEY, type EntriesPage } from "@/hooks/useEntries";

function minimalProjection(
  overrides: Partial<PublicationSidebarProjection> = {}
): PublicationSidebarProjection {
  return {
    viewerDid: "did:plc:viewer",
    folders: [],
    publicationPrefs: [],
    allPublicationRows: [],
    myPublications: [],
    subscribedUnfoldered: [
      {
        publicationId: "rss:https://example.com/feed.xml",
        authorDid: "did:web:skyreader.rss",
        authorHandle: "RSS",
        title: "Example RSS",
        discoveredAt: "2026-01-01T00:00:00.000Z",
        appViewScope: {
          authorDid: "did:web:skyreader.rss",
          publicationAtUri: null,
          publicationScopeAtUris: [],
          publicationSiteUrls: ["https://example.com/feed.xml"],
        },
        unreadCount: 2,
      },
    ],
    followingTabPublications: [],
    enrollAuthorDids: [],
    refreshedAt: new Date().toISOString(),
    unreadCountsByPublicationId: { "rss:https://example.com/feed.xml": 5 },
    ...overrides,
  };
}

function row(
  publicationId: string,
  title: string,
  unreadCount?: number
): PublicationSidebarProjection["allPublicationRows"][number] {
  return {
    publicationId,
    authorDid: `did:plc:${publicationId}`,
    authorHandle: title.toLowerCase().replace(/\s+/g, "-"),
    title,
    discoveredAt: "2026-01-01T00:00:00.000Z",
    appViewScope: {
      authorDid: `did:plc:${publicationId}`,
      publicationAtUri: null,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
    },
    ...(unreadCount !== undefined ? { unreadCount } : {}),
  };
}

describe("writeStreamedEntriesPage", () => {
  const publicationId = "rss:aHR0cHM6Ly9leGFtcGxlLnRlc3QvcnNz";
  const queryKey = [...ENTRIES_QUERY_KEY("did:plc:viewer", publicationId), "all"];
  const cached = {
    pages: [
      { entries: [{ entryId: "one", title: "One", publishedAt: "2026-01-01" }], cursor: "next" },
      { entries: [{ entryId: "two", title: "Two", publishedAt: "2026-01-01" }] },
    ],
    pageParams: [undefined, "next"],
  };

  for (const filter of ["all", "unread"] as const) {
    for (const source of ["live_projection", "projection_cache"] as const) {
      it(`rejects ${source} ${filter} chunks after a read-state cancellation`, async () => {
        const qc = new QueryClient();
        const key = [...ENTRIES_QUERY_KEY("did:plc:viewer", publicationId), filter];
        // Capture before the eventual target scope even exists in the cache.
        const revisions = captureFeedRefreshRevisions(qc);
        qc.setQueryData(key, cached, { updatedAt: 1 });
        await cancelViewerFeedRefreshes(qc, "did:plc:viewer");
        qc.setQueryData<InfiniteData<EntriesPage>>(key, current => ({
          ...current!, pages: current!.pages.map(page => ({ ...page, entries: page.entries.map(entry => ({ ...entry, isRead: false })) })),
        }));
        await qc.invalidateQueries({ queryKey: key, exact: true, refetchType: "none" });
        const before = qc.getQueryState(key)!;
        writeStreamedEntriesPage(qc, "did:plc:viewer", {
          publicationId: encodeURIComponent(publicationId), source,
          cachedAt: "2099-01-01T00:00:00Z",
          entries: [{ ...cached.pages[0].entries[0], isRead: true }],
        }, filter, revisions);
        const after = qc.getQueryState(key)!;
        expect(after.data).toBe(before.data);
        expect(after.dataUpdatedAt).toBe(before.dataUpdatedAt);
        expect(after.isInvalidated).toBe(true);
        expect(qc.getQueryDefaults(key)).toEqual({});
        expect(qc.getQueryCache().getAll()).toHaveLength(1);
        qc.clear();
      });
    }
  }

  it("copies nonzero stream-start generations and looks up the complete normalized query identity", () => {
    const qc = new QueryClient();
    qc.setQueryData(queryKey, cached, { updatedAt: 1 });
    advanceFeedRefreshRevision(qc, queryKey);
    const revisions = captureFeedRefreshRevisions(qc);
    advanceFeedRefreshRevision(qc, [...queryKey.slice(0, -1), "unread"]);
    advanceFeedRefreshRevision(qc, ["entries", "did:plc:other", publicationId, "all"]);
    const payload = { publicationId: encodeURIComponent(publicationId), entries: [fresh], source: "live_projection" as const };
    writeStreamedEntriesPage(qc, "did:plc:viewer", payload, "all", revisions);
    expect(qc.getQueryData<InfiniteData<EntriesPage>>(queryKey)?.pages[0].entries[0]).toEqual(fresh);
    advanceFeedRefreshRevision(qc, queryKey);
    const before = qc.getQueryState(queryKey)!;
    writeStreamedEntriesPage(qc, "did:plc:viewer", { ...payload, entries: [] }, "all", revisions);
    expect(qc.getQueryState(queryKey)?.data).toBe(before.data);
    expect(qc.getQueryState(queryKey)?.dataUpdatedAt).toBe(before.dataUpdatedAt);
    expect(revisions(queryKey)).toBe(1);
    qc.clear();
  });

  for (const id of [publicationId, encodeURIComponent(publicationId)]) {
    it(`preserves all cached pages and freshness when unavailable (${id})`, () => {
      const qc = new QueryClient();
      const updatedAt = Date.parse("2026-01-01T00:00:00Z");
      qc.setQueryData(queryKey, cached, { updatedAt });
      const before = qc.getQueryData<InfiniteData<EntriesPage>>(queryKey);
      for (let attempt = 0; attempt < 2; attempt++) {
        writeStreamedEntriesPage(qc, "did:plc:viewer", {
          publicationId: id, entries: [], source: "unavailable",
        });
      }
      expect(qc.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toBe(before);
      expect(qc.getQueryState(queryKey)?.dataUpdatedAt).toBe(updatedAt);
      expect(qc.getQueryState(queryKey)?.isInvalidated).toBe(false);
      expect(qc.getQueryCache().getAll()).toHaveLength(1);
      qc.clear();
    });

    it(`leaves unavailable cache misses absent (${id})`, () => {
      const qc = new QueryClient();
      writeStreamedEntriesPage(qc, "did:plc:viewer", {
        publicationId: id, entries: [], source: "unavailable",
      });
      expect(qc.getQueryState(queryKey)).toBeUndefined();
      expect(qc.getQueryCache().getAll()).toHaveLength(0);
      qc.clear();
    });
  }

  it("preserves All history when a live empty first page arrives", () => {
    const qc = new QueryClient();
    qc.setQueryData(queryKey, cached, { updatedAt: 1 });
    const receivedAt = Date.now();
    writeStreamedEntriesPage(qc, "did:plc:viewer", {
      publicationId, entries: [], source: "live_projection",
    });
    expect(qc.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toEqual(cached);
    expect(qc.getQueryState(queryKey)?.dataUpdatedAt).toBeGreaterThanOrEqual(receivedAt);
    qc.clear();
  });

  it("merges a newer cached empty All page using its original timestamp", () => {
    const qc = new QueryClient();
    qc.setQueryData(queryKey, cached, { updatedAt: 1 });
    const cachedAt = "2026-01-02T00:00:00Z";
    writeStreamedEntriesPage(qc, "did:plc:viewer", {
      publicationId, entries: [], source: "projection_cache", cachedAt,
      expiresAt: "2026-01-03T00:00:00Z",
    });
    expect(qc.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toEqual(cached);
    expect(qc.getQueryState(queryKey)?.dataUpdatedAt).toBe(Date.parse(cachedAt));
    qc.clear();
  });

  const existingUpdatedAt = Date.parse("2026-01-02T00:00:00Z");
  const freshCachedAt = "2026-01-03T00:00:00Z";
  const fresh = { ...cached.pages[1].entries[0], title: "Updated Two" };

  for (const filter of ["all", "unread"] as const) {
    for (const entries of [[], [fresh]]) {
      for (const cachedAt of ["2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", undefined, "invalid"]) {
        it(`rejects stale/invalid cached ${filter} pages (${entries.length} rows, ${cachedAt})`, () => {
          const qc = new QueryClient();
          const key = [...ENTRIES_QUERY_KEY("did:plc:viewer", publicationId), filter];
          qc.setQueryData(key, cached, { updatedAt: existingUpdatedAt });
          const before = qc.getQueryData<InfiniteData<EntriesPage>>(key);
          writeStreamedEntriesPage(qc, "did:plc:viewer", {
            publicationId: encodeURIComponent(publicationId), entries, source: "projection_cache", cachedAt,
          }, filter);
          expect(qc.getQueryData<InfiniteData<EntriesPage>>(key)).toBe(before);
          expect(qc.getQueryState(key)?.dataUpdatedAt).toBe(existingUpdatedAt);
          expect(qc.getQueryCache().getAll()).toHaveLength(1);
          qc.clear();
        });
      }
    }
  }

  for (const source of ["live_projection", "projection_cache"] as const) {
    it(`merges accepted ${source} All rows retaining tail cursors and page params`, () => {
      const qc = new QueryClient();
      qc.setQueryData(queryKey, {
        pages: [cached.pages[0], { ...cached.pages[1], cursor: "tail-cursor" }],
        pageParams: ["first-param", "next"],
      }, { updatedAt: existingUpdatedAt });
      const receivedAt = Date.now();
      writeStreamedEntriesPage(qc, "did:plc:viewer", {
        publicationId, entries: [fresh, fresh], cursor: "fresh-cursor", source, cachedAt: freshCachedAt,
      });
      expect(qc.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toEqual({
        pages: [
          { entries: [fresh, ...cached.pages[0].entries], cursor: "fresh-cursor" },
          { entries: [], cursor: "tail-cursor" },
        ],
        pageParams: ["first-param", "next"],
      });
      if (source === "projection_cache") {
        expect(qc.getQueryState(queryKey)?.dataUpdatedAt).toBe(Date.parse(freshCachedAt));
      } else {
        expect(qc.getQueryState(queryKey)?.dataUpdatedAt).toBeGreaterThanOrEqual(receivedAt);
      }
      qc.clear();
    });

    for (const entries of [[], [fresh]]) {
      it(`keeps accepted ${source} Unread authoritative (${entries.length} rows)`, () => {
        const qc = new QueryClient();
        const key = [...ENTRIES_QUERY_KEY("did:plc:viewer", publicationId), "unread"];
        qc.setQueryData(key, cached, { updatedAt: existingUpdatedAt });
        writeStreamedEntriesPage(qc, "did:plc:viewer", {
          publicationId, entries, source, cachedAt: freshCachedAt, cursor: "unread-next",
        }, "unread");
        expect(qc.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual({
          pages: [{ entries, cursor: "unread-next" }], pageParams: [undefined],
        });
        qc.clear();
      });
    }


  }

  for (const entries of [[], [{ entryId: "stream", title: "Stream", publishedAt: "2026-01-01" }]]) {
    it(`retains a newer completed fetch's All history when live bootstrap arrives (${entries.length} rows)`, async () => {
      const qc = new QueryClient();
      const receivedAt = Date.now();
      await qc.fetchInfiniteQuery({
        queryKey, initialPageParam: undefined as string | undefined,
        queryFn: ({ pageParam }) => Promise.resolve(pageParam ? cached.pages[1] : cached.pages[0]),
        getNextPageParam: (page) => page.cursor,
        pages: 2,
      });
      expect(qc.getQueryState(queryKey)?.dataUpdatedAt).toBeGreaterThanOrEqual(receivedAt);
      writeStreamedEntriesPage(qc, "did:plc:viewer", {
        publicationId, entries, source: "live_projection",
      });
      expect(qc.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toEqual({
        pages: [{ ...cached.pages[0], entries: [...entries, ...cached.pages[0].entries] }, cached.pages[1]],
        pageParams: cached.pageParams,
      });
      qc.clear();
    });
  }

  it("seeds only the target account on a cache miss with projection freshness", () => {
    const qc = new QueryClient();
    qc.setQueryData(queryKey, cached, { updatedAt: Date.parse(freshCachedAt) });
    const before = qc.getQueryData<InfiniteData<EntriesPage>>(queryKey);
    const otherKey = [...ENTRIES_QUERY_KEY("did:plc:other", publicationId), "all"];
    writeStreamedEntriesPage(qc, "did:plc:other", {
      publicationId, entries: [], cursor: "next", source: "projection_cache", cachedAt: "2026-01-02T00:00:00Z",
    });
    expect(qc.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toBe(before);
    expect(qc.getQueryState(queryKey)?.dataUpdatedAt).toBe(Date.parse(freshCachedAt));
    expect(qc.getQueryData<InfiniteData<EntriesPage>>(otherKey)).toEqual({ pages: [{ entries: [], cursor: "next" }], pageParams: [undefined] });
    expect(qc.getQueryState(otherKey)?.dataUpdatedAt).toBe(existingUpdatedAt);
    qc.clear();
  });

  it("normalizes publication ids for the entries query cache key", () => {
    const qc = new QueryClient();
    writeStreamedEntriesPage(qc, "did:plc:viewer", {
      publicationId: "at://did:plc:author/site.standard.publication/pub1",
      entries: [{ entryId: "at://did:plc:author/site.standard.document/a", title: "A", publishedAt: "2026-01-01T00:00:00.000Z" }],
      cursor: "next",
      source: "live_projection",
    });

    const cached = qc.getQueryData([
      ...ENTRIES_QUERY_KEY(
        "did:plc:viewer",
        "at://did:plc:author/site.standard.publication/pub1"
      ),
      "all",
    ]);
    expect(cached).toBeDefined();
  });
});

describe("applySidebarFoldersEvent", () => {
  it("keeps cached full sidebar shape when a warm priority chunk is sparse", () => {
    const alpha = row("pub-a", "Alpha", 7);
    const beta = row("pub-b", "Beta", 0);
    const gamma = row("pub-c", "Gamma", 2);
    const cached = minimalProjection({
      allPublicationRows: [alpha, beta, gamma],
      subscribedUnfoldered: [alpha, beta],
      followingTabPublications: [gamma],
      folderSections: [
        {
          folderRkey: "folder1",
          folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
          publications: [beta, gamma],
        },
      ],
      unreadCountsByPublicationId: {
        "pub-a": 7,
        "pub-b": 0,
        "pub-c": 2,
      },
    });

    const priority = minimalProjection({
      refreshedAt: "2026-01-02T00:00:00.000Z",
      allPublicationRows: [row("pub-a", "Alpha Updated")],
      subscribedUnfoldered: [row("pub-a", "Alpha Updated")],
      followingTabPublications: [],
      folderSections: undefined,
      unreadCountsByPublicationId: undefined,
    });

    const merged = applySidebarPriorityEvent(cached, priority);

    expect(merged.allPublicationRows.map((item) => item.title)).toEqual([
      "Alpha Updated",
      "Beta",
      "Gamma",
    ]);
    expect(merged.subscribedUnfoldered.map((item) => item.title)).toEqual([
      "Alpha Updated",
      "Beta",
    ]);
    expect(merged.followingTabPublications.map((item) => item.title)).toEqual([
      "Gamma",
    ]);
    expect(
      merged.folderSections?.[0]?.publications.map((item) => item.title)
    ).toEqual(["Beta", "Gamma"]);
    expect(merged.unreadCountsByPublicationId).toEqual({
      "pub-a": 7,
      "pub-b": 0,
      "pub-c": 2,
    });
  });

  it("keeps folder contents when a refresh returns folder sections with no publications", () => {
    // refreshSidebar returns the priority tier, which builds folder sections
    // without their publications. Replacing the cached projection with that payload would empty
    // every folder in the sidebar, so the merge has to preserve the cached contents.
    const alpha = row("pub-a", "Alpha", 7);
    const beta = row("pub-b", "Beta", 1);
    const cached = minimalProjection({
      allPublicationRows: [alpha, beta],
      subscribedUnfoldered: [alpha],
      followingTabPublications: [beta],
      folderSections: [
        {
          folderRkey: "folder1",
          folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
          publications: [beta],
        },
      ],
    });

    const refreshed = minimalProjection({
      refreshedAt: "2026-01-02T00:00:00.000Z",
      allPublicationRows: [row("pub-a", "Alpha Renamed", 3)],
      subscribedUnfoldered: [row("pub-a", "Alpha Renamed", 3)],
      followingTabPublications: [],
      folderSections: [
        {
          folderRkey: "folder1",
          folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
          publications: [],
        },
      ],
      unreadCountsByPublicationId: undefined,
    });

    const merged = applySidebarPriorityEvent(cached, refreshed);

    expect(
      merged.folderSections?.[0]?.publications.map((item) => item.title)
    ).toEqual(["Beta"]);
    // The carried-over Following tab must survive a refresh that omits it.
    expect(merged.followingTabPublications.map((item) => item.title)).toEqual([
      "Beta",
    ]);
    expect(merged.subscribedUnfoldered.map((item) => item.title)).toEqual([
      "Alpha Renamed",
    ]);
  });

  it("merges folder layout without overwriting unreadCounts from the prior unreadCounts event", () => {
    const base = applyUnreadCountsEvent(minimalProjection(), {
      "rss:https://example.com/feed.xml": 5,
    }, { replacePublicationIds: ["rss:https://example.com/feed.xml"] });

    const merged = applySidebarFoldersEvent(base, {
      folderSections: [],
      allPublicationRows: [
        {
          ...base.subscribedUnfoldered[0]!,
          unreadCount: 2,
        },
      ],
    });

    expect(merged.unreadCountsByPublicationId?.["rss:https://example.com/feed.xml"]).toBe(
      5
    );
  });

  it("applies late folder unread count replacement after folder rows arrive", () => {
    const withFolders = applySidebarFoldersEvent(minimalProjection(), {
      folderSections: [
        {
          folderRkey: "folder1",
          folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
          publications: [
            {
              ...minimalProjection().subscribedUnfoldered[0]!,
              publicationId: "rss:https://example.com/folder-feed.xml",
              unreadCount: undefined,
            },
          ],
        },
      ],
      allPublicationRows: [
        {
          ...minimalProjection().subscribedUnfoldered[0]!,
          publicationId: "rss:https://example.com/folder-feed.xml",
          unreadCount: undefined,
        },
      ],
    });

    const counted = applyUnreadCountsEvent(
      withFolders,
      { "rss:https://example.com/folder-feed.xml": 7 },
      { replacePublicationIds: ["rss:https://example.com/folder-feed.xml"] }
    );

    expect(
      counted.unreadCountsByPublicationId?.[
        "rss:https://example.com/folder-feed.xml"
      ]
    ).toBe(7);
    expect(counted.folderSections?.[0]?.publications[0]?.unreadCount).toBe(7);
  });

  it("applies a sidebarSection without replacing unrelated folder sections", () => {
    const alpha = row("pub-a", "Alpha", 1);
    const beta = row("pub-b", "Beta", 2);
    const gamma = row("pub-c", "Gamma", 3);
    const untouchedSection = {
      folderRkey: "folder2",
      folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder2",
      publications: [gamma],
    };
    const base = minimalProjection({
      allPublicationRows: [alpha, beta, gamma],
      folderSections: [
        {
          folderRkey: "folder1",
          folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
          publications: [alpha],
        },
        untouchedSection,
      ],
      unreadCountsByPublicationId: {
        "pub-a": 1,
        "pub-b": 2,
        "pub-c": 3,
      },
    });

    const merged = applySidebarSectionEvent(base, {
      sectionKey: "folder:folder1",
      folderRkey: "folder1",
      folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
      publications: [row("pub-b", "Beta Updated")],
      unreadCounts: { "pub-b": 0 },
      replacePublicationIds: ["pub-b"],
      refreshedAt: "2026-01-03T00:00:00.000Z",
    });

    expect(merged.folderSections?.[1]).toBe(untouchedSection);
    expect(merged.folderSections?.[0]?.publications.map((item) => item.title)).toEqual([
      "Beta Updated",
    ]);
    expect(merged.unreadCountsByPublicationId?.["pub-b"]).toBe(0);
    expect(merged.folderSections?.[0]?.publications[0]?.unreadCount).toBe(0);
    expect(merged.allPublicationRows.find((item) => item.publicationId === "pub-a")).toBe(alpha);
  });

  it("ignores older sidebarSection generations", () => {
    const alpha = row("pub-a", "Alpha", 1);
    const base = minimalProjection({
      allPublicationRows: [alpha],
      folderSections: [
        {
          folderRkey: "folder1",
          folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
          publications: [alpha],
        },
      ],
      sidebarSectionGenerations: { "folder:folder1": 10 },
    });

    const merged = applySidebarSectionEvent(base, {
      sectionKey: "folder:folder1",
      folderRkey: "folder1",
      folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
      publications: [row("pub-a", "Stale Alpha")],
      refreshedAt: "2026-01-03T00:00:00.000Z",
      sectionGeneration: 9,
    });

    expect(merged).toBe(base);
    expect(merged.folderSections?.[0]?.publications[0]?.title).toBe("Alpha");
  });
});
