import { describe, expect, test } from "bun:test";

import {
  appViewScopeFromProjection,
  sidebarIncludesUnreadCounts,
  unreadCountsMapFromProjection,
  type PublicationSidebarProjection,
} from "@/lib/publicationProjectionClient";

describe("publicationProjectionClient", () => {
  test("appViewScopeFromProjection finds scope by publication id", () => {
    const projection: PublicationSidebarProjection = {
      viewerDid: "did:plc:viewer",
      folders: [],
      publicationPrefs: [],
      allPublicationRows: [
        {
          publicationId: "at://did:plc:author/site.standard.publication/pub1",
          authorDid: "did:plc:author",
          authorHandle: "author",
          title: "Pub",
          discoveredAt: "2026-01-01T00:00:00.000Z",
          appViewScope: {
            authorDid: "did:plc:author",
            publicationAtUri: "at://did:plc:author/site.standard.publication/pub1",
            publicationScopeAtUris: [
              "at://did:plc:author/com.standard.publication/pub1",
            ],
            publicationSiteUrls: ["https://example.com"],
          },
        },
      ],
      myPublications: [],
      subscribedUnfoldered: [],
      followingTabPublications: [],
      enrollAuthorDids: ["did:plc:author"],
      refreshedAt: "2026-01-01T00:00:00.000Z",
    };

    const scope = appViewScopeFromProjection(
      projection,
      "at://did:plc:author/site.standard.publication/pub1"
    );
    expect(scope?.publicationScopeAtUris).toContain(
      "at://did:plc:author/com.standard.publication/pub1"
    );
    expect(scope?.publicationSiteUrls).toContain("https://example.com");
  });

  test("unreadCountsMapFromProjection prefers unreadCountsByPublicationId over row embed", () => {
    const projection: PublicationSidebarProjection = {
      viewerDid: "did:plc:viewer",
      folders: [],
      publicationPrefs: [],
      allPublicationRows: [
        {
          publicationId: "did:plc:alice",
          authorDid: "did:plc:alice",
          authorHandle: "alice",
          title: "Alice",
          discoveredAt: "2026-01-01T00:00:00.000Z",
          unreadCount: 4,
          appViewScope: {
            authorDid: "did:plc:alice",
            publicationAtUri: null,
            publicationScopeAtUris: [],
            publicationSiteUrls: [],
          },
        },
      ],
      myPublications: [],
      subscribedUnfoldered: [],
      followingTabPublications: [],
      enrollAuthorDids: [],
      refreshedAt: "2026-01-01T00:00:00.000Z",
      unreadCountsByPublicationId: { "did:plc:alice": 1 },
    };

    const map = unreadCountsMapFromProjection(projection);
    expect(map.get("did:plc:alice")).toBe(1);
  });

  test("unreadCountsMapFromProjection includes folder section publications", () => {
    const projection: PublicationSidebarProjection = {
      viewerDid: "did:plc:viewer",
      folders: [],
      publicationPrefs: [],
      allPublicationRows: [],
      myPublications: [],
      subscribedUnfoldered: [],
      followingTabPublications: [],
      folderSections: [
        {
          folderRkey: "folder1",
          folderUri: "at://did:plc:viewer/com.thesocialwire.folder/folder1",
          publications: [
            {
              publicationId: "at://did:plc:author/site.standard.publication/pub1",
              authorDid: "did:plc:author",
              authorHandle: "author",
              title: "Folder Pub",
              discoveredAt: "2026-01-01T00:00:00.000Z",
              unreadCount: 2,
              appViewScope: {
                authorDid: "did:plc:author",
                publicationAtUri:
                  "at://did:plc:author/site.standard.publication/pub1",
                publicationScopeAtUris: [],
                publicationSiteUrls: [],
              },
            },
          ],
        },
      ],
      enrollAuthorDids: [],
      refreshedAt: "2026-01-01T00:00:00.000Z",
    };

    const map = unreadCountsMapFromProjection(projection);
    expect(
      map.get("at://did:plc:author/site.standard.publication/pub1")
    ).toBe(2);
  });

  test("appViewScopeFromProjection finds scope in folder sections", () => {
    const projection: PublicationSidebarProjection = {
      viewerDid: "did:plc:viewer",
      folders: [],
      publicationPrefs: [],
      allPublicationRows: [],
      myPublications: [],
      subscribedUnfoldered: [],
      followingTabPublications: [],
      folderSections: [
        {
          folderRkey: "folder1",
          folderUri: "at://did:plc:viewer/com.thesocialwire.folder/folder1",
          publications: [
            {
              publicationId: "at://did:plc:author/site.standard.publication/pub1",
              authorDid: "did:plc:author",
              authorHandle: "author",
              title: "Folder Pub",
              discoveredAt: "2026-01-01T00:00:00.000Z",
              appViewScope: {
                authorDid: "did:plc:author",
                publicationAtUri:
                  "at://did:plc:author/site.standard.publication/pub1",
                publicationScopeAtUris: [],
                publicationSiteUrls: [],
              },
            },
          ],
        },
      ],
      enrollAuthorDids: ["did:plc:author"],
      refreshedAt: "2026-01-01T00:00:00.000Z",
    };

    const scope = appViewScopeFromProjection(
      projection,
      "at://did:plc:author/site.standard.publication/pub1"
    );
    expect(scope?.authorDid).toBe("did:plc:author");
  });

  test("sidebarIncludesUnreadCounts is true when rows embed unreadCount", () => {
    const projection: PublicationSidebarProjection = {
      viewerDid: "did:plc:viewer",
      folders: [],
      publicationPrefs: [],
      allPublicationRows: [
        {
          publicationId: "did:plc:alice",
          authorDid: "did:plc:alice",
          authorHandle: "alice",
          title: "Alice",
          discoveredAt: "2026-01-01T00:00:00.000Z",
          unreadCount: 0,
          appViewScope: {
            authorDid: "did:plc:alice",
            publicationAtUri: null,
            publicationScopeAtUris: [],
            publicationSiteUrls: [],
          },
        },
      ],
      myPublications: [],
      subscribedUnfoldered: [],
      followingTabPublications: [],
      enrollAuthorDids: [],
      refreshedAt: "2026-01-01T00:00:00.000Z",
    };

    expect(sidebarIncludesUnreadCounts(projection)).toBe(true);
  });
});
