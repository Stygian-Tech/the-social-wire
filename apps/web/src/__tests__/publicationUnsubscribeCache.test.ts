import { describe, expect, it } from "bun:test";
import { QueryClient, type InfiniteData } from "@tanstack/react-query";

import type { EntriesPage } from "@/hooks/useEntries";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type {
  PublicationSidebarProjection,
  SidebarPublicationRow,
} from "@/lib/publicationProjectionClient";
import {
  removePublicationFromEntryCaches,
  removePublicationFromSidebarProjection,
} from "@/lib/publicationUnsubscribeCache";

const viewerDid = "did:plc:viewer";
const publicationId =
  "at://did:plc:author/site.standard.publication/publication1";
const publicationAlias =
  "at://did:plc:author/com.standard.publication/publication1";

function row(id: string, title: string): SidebarPublicationRow {
  return {
    publicationId: id,
    authorDid: "did:plc:author",
    authorHandle: "author.test",
    title,
    discoveredAt: "2026-01-01T00:00:00.000Z",
    appViewScope: {
      authorDid: "did:plc:author",
      publicationAtUri: id,
      publicationScopeAtUris: [id],
      publicationSiteUrls: [],
    },
  };
}

const removedRow = row(publicationAlias, "Removed");
const retainedRow = row("did:plc:retained", "Retained");

function projection(): PublicationSidebarProjection {
  return {
    viewerDid,
    folders: [],
    publicationPrefs: [],
    folderSections: [
      {
        folderRkey: "folder1",
        folderUri: `at://${viewerDid}/app.thesocialwire.folder/folder1`,
        publications: [removedRow, retainedRow],
      },
    ],
    allPublicationRows: [removedRow, retainedRow],
    myPublications: [],
    subscribedUnfoldered: [removedRow],
    followingTabPublications: [removedRow, retainedRow],
    enrollAuthorDids: [],
    refreshedAt: "2026-01-01T00:00:00.000Z",
    unreadCountsByPublicationId: {
      [publicationId]: 4,
      [retainedRow.publicationId]: 2,
    },
  };
}

describe("publication unsubscribe cache reconciliation", () => {
  it("removes publication aliases from every sidebar section and unread map", () => {
    const next = removePublicationFromSidebarProjection(
      projection(),
      publicationId,
    );

    expect(next?.allPublicationRows.map((item) => item.title)).toEqual([
      "Retained",
    ]);
    expect(next?.subscribedUnfoldered).toEqual([]);
    expect(next?.followingTabPublications.map((item) => item.title)).toEqual([
      "Retained",
    ]);
    expect(next?.folderSections?.[0]?.publications.map((item) => item.title)).toEqual([
      "Retained",
    ]);
    expect(next?.unreadCountsByPublicationId).toEqual({
      [retainedRow.publicationId]: 2,
    });
  });

  it("deletes publication pages and strips its articles from every aggregate cache", () => {
    const queryClient = new QueryClient();
    const publicationQueryKey = ["entries", viewerDid, publicationAlias, "all"];
    const subscribedQueryKey = [
      "aggregateEntries",
      viewerDid,
      "subscribed",
      "",
      "all",
    ];
    const followingQueryKey = [
      "aggregateEntries",
      viewerDid,
      "following",
      "",
      "all",
    ];
    const pages: InfiniteData<EntriesPage> = {
      pages: [
        {
          entries: [
            {
              entryId: "at://did:plc:author/site.standard.document/removed",
              publicationId: publicationAlias,
              title: "Removed",
              publishedAt: "2026-01-02T00:00:00.000Z",
            },
            {
              entryId: "at://did:plc:retained/site.standard.document/retained",
              publicationId: retainedRow.publicationId,
              title: "Retained",
              publishedAt: "2026-01-01T00:00:00.000Z",
            },
          ],
        },
      ],
      pageParams: [undefined],
    };
    queryClient.setQueryData(publicationQueryKey, pages);
    queryClient.setQueryData(subscribedQueryKey, pages);
    queryClient.setQueryData(followingQueryKey, pages);

    const publication: DiscoveredPublication = {
      publicationId,
      authorDid: "did:plc:author",
      authorHandle: "author.test",
      title: "Removed",
      discoveredAt: "2026-01-01T00:00:00.000Z",
    };
    removePublicationFromEntryCaches(queryClient, viewerDid, publication);

    expect(queryClient.getQueryData(publicationQueryKey)).toBeUndefined();
    for (const key of [subscribedQueryKey, followingQueryKey]) {
      const cached = queryClient.getQueryData<InfiniteData<EntriesPage>>(key);
      expect(cached?.pages[0]?.entries.map((entry) => entry.title)).toEqual([
        "Retained",
      ]);
    }
  });
});
