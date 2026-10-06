import { describe, expect, it } from "bun:test";
import { QueryClient } from "@tanstack/react-query";
import { applyBootstrapStreamEvent } from "@/lib/bootstrapStreamState";
import { invalidateConfirmedReadStateQueries } from "@/lib/pendingReadStateOverlay";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";

const projection = (viewerDid: string): PublicationSidebarProjection => ({
  viewerDid,
  folders: [],
  publicationPrefs: [],
  allPublicationRows: [],
  myPublications: [],
  subscribedUnfoldered: [],
  followingTabPublications: [],
  enrollAuthorDids: [],
  refreshedAt: "2026-10-05T00:00:00.000Z",
});

describe("versioned publication sidebar cache", () => {
  it("seeds the filtered bootstrap without retaining legacy podcast rows or badges", () => {
    const client = new QueryClient();
    const did = "did:plc:viewer";
    const legacyKey = ["publicationSidebarProjection", did];
    const oldProjection = projection(did);
    oldProjection.subscribedUnfoldered = [{
      publicationId: "rss:podcast",
      authorDid: "did:web:skyreader.rss",
      authorHandle: "podcast.example",
      title: "Podcast",
      discoveredAt: oldProjection.refreshedAt,
      unreadCount: 42,
      appViewScope: {
        authorDid: "did:web:skyreader.rss",
        publicationAtUri: null,
        publicationScopeAtUris: [],
        publicationSiteUrls: ["https://podcast.example/feed"],
      },
    }];
    oldProjection.unreadCountsByPublicationId = { "rss:podcast": 42 };
    client.setQueryData(legacyKey, oldProjection);
    const currentKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
    const fresh = projection(did);
    fresh.subscribedUnfoldered = [{
      ...oldProjection.subscribedUnfoldered[0]!,
      publicationId: "rss:article",
      title: "Articles",
      unreadCount: 3,
    }];
    fresh.unreadCountsByPublicationId = { "rss:article": 3 };

    const applied = applyBootstrapStreamEvent({
      projection: client.getQueryData(currentKey),
      event: { kind: "sidebarPriority", payload: fresh },
    });
    client.setQueryData(currentKey, applied.projection);

    const cached = client.getQueryData<PublicationSidebarProjection>(currentKey)!;
    expect(cached.subscribedUnfoldered.map((row) => row.publicationId)).toEqual(["rss:article"]);
    expect(cached.unreadCountsByPublicationId).toEqual({ "rss:article": 3 });
    expect(client.getQueryData<PublicationSidebarProjection>(legacyKey)).toEqual(oldProjection);
    client.clear();
  });

  it("preserves viewer-scoped read-state invalidation with the version suffix", async () => {
    const client = new QueryClient();
    const did = "did:plc:viewer";
    const currentKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
    const otherKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("did:plc:other");
    client.setQueryData(currentKey, projection(did));
    client.setQueryData(otherKey, projection("did:plc:other"));

    await invalidateConfirmedReadStateQueries(client, did);

    expect(client.getQueryState(currentKey)?.isInvalidated).toBe(true);
    expect(client.getQueryState(otherKey)?.isInvalidated).toBe(false);
    client.clear();
  });
});
