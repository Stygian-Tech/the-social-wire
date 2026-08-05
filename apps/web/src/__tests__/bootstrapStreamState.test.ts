import { describe, expect, it } from "bun:test";
import { QueryClient } from "@tanstack/react-query";

import {
  applySidebarPriorityEvent,
  applySidebarFoldersEvent,
  applySidebarSectionEvent,
  applyUnreadCountsEvent,
  writeStreamedEntriesPage,
} from "@/lib/bootstrapStreamState";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { ENTRIES_QUERY_KEY } from "@/hooks/useEntries";

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
  it("normalizes publication ids for the entries query cache key", () => {
    const qc = new QueryClient();
    writeStreamedEntriesPage(qc, "did:plc:viewer", {
      publicationId: "at://did:plc:author/site.standard.publication/pub1",
      entries: [{ entryId: "at://did:plc:author/site.standard.document/a", title: "A", publishedAt: "2026-01-01T00:00:00.000Z" }],
      cursor: "next",
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
    // POST /v1/publications/refresh returns the priority tier, which builds folder sections
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
