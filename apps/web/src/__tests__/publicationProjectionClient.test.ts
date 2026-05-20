import { describe, expect, test } from "bun:test";

import {
  appViewScopeFromProjection,
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
});
