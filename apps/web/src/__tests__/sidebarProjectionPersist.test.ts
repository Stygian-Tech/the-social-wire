import { describe, expect, test } from "bun:test";

import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { shouldPersistSidebarProjection } from "@/lib/sidebarProjectionPersist";

const emptyProjection: PublicationSidebarProjection = {
  viewerDid: "did:plc:viewer",
  folders: [],
  publicationPrefs: [],
  allPublicationRows: [],
  myPublications: [],
  subscribedUnfoldered: [],
  followingTabPublications: [],
  enrollAuthorDids: [],
  refreshedAt: "2026-01-01T00:00:00.000Z",
};

describe("shouldPersistSidebarProjection", () => {
  test("persists completed empty sidebar snapshots", () => {
    expect(shouldPersistSidebarProjection(emptyProjection)).toBe(true);
  });

  test("skips incomplete snapshots without refreshedAt", () => {
    expect(
      shouldPersistSidebarProjection({
        ...emptyProjection,
        refreshedAt: "",
      })
    ).toBe(false);
  });

  test("skips oversized publication lists", () => {
    expect(
      shouldPersistSidebarProjection({
        ...emptyProjection,
        allPublicationRows: Array.from({ length: 251 }, (_, index) => ({
          publicationId: `at://did:plc:author/site.standard.publication/pub${index}`,
          authorDid: "did:plc:author",
          authorHandle: "author",
          title: `Pub ${index}`,
          discoveredAt: "2026-01-01T00:00:00.000Z",
          appViewScope: {
            authorDid: "did:plc:author",
            publicationAtUri: null,
            publicationScopeAtUris: [],
            publicationSiteUrls: [],
          },
        })),
      })
    ).toBe(false);
  });
});
