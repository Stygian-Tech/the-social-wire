import { describe, expect, test } from "bun:test";

import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import {
  applyPublicationFolderMoveToProjection,
  reconcilePublicationPrefAfterWrite,
} from "@/lib/optimisticPublicationFolderMove";

const publicationRow = {
  publicationId: "at://did:plc:author/site.standard.publication/pub1",
  authorDid: "did:plc:author",
  authorHandle: "author",
  title: "Example Pub",
  discoveredAt: "2026-01-01T00:00:00.000Z",
  appViewScope: {
    authorDid: "did:plc:author",
    publicationAtUri: "at://did:plc:author/site.standard.publication/pub1",
    publicationScopeAtUris: [],
    publicationSiteUrls: [],
  },
};

const baseProjection: PublicationSidebarProjection = {
  viewerDid: "did:plc:viewer",
  folders: [
    {
      uri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
      rkey: "folder1",
      value: { name: "Tech" },
    },
  ],
  publicationPrefs: [],
  allPublicationRows: [publicationRow],
  myPublications: [],
  subscribedUnfoldered: [publicationRow],
  followingTabPublications: [],
  enrollAuthorDids: [],
  refreshedAt: "2026-01-01T00:00:00.000Z",
  folderSections: [
    {
      folderRkey: "folder1",
      folderUri: "at://did:plc:viewer/app.thesocialwire.folder/folder1",
      publications: [],
    },
  ],
};

describe("optimisticPublicationFolderMove", () => {
  test("moves an unfoldered publication into a folder", () => {
    const next = applyPublicationFolderMoveToProjection(baseProjection, {
      publicationId: publicationRow.publicationId,
      folderId: "folder1",
    });

    expect(next?.subscribedUnfoldered).toEqual([]);
    expect(next?.folderSections?.[0]?.publications).toHaveLength(1);
    expect(next?.publicationPrefs[0]?.value.folderId).toBe("folder1");
  });

  test("moves a foldered publication back to Publications", () => {
    const foldered = applyPublicationFolderMoveToProjection(baseProjection, {
      publicationId: publicationRow.publicationId,
      folderId: "folder1",
    });
    const next = applyPublicationFolderMoveToProjection(foldered, {
      publicationId: publicationRow.publicationId,
      folderId: null,
    });

    expect(next?.subscribedUnfoldered).toHaveLength(1);
    expect(next?.folderSections?.[0]?.publications).toEqual([]);
    expect(next?.publicationPrefs[0]?.value.folderId).toBeUndefined();
  });

  test("reconcilePublicationPrefAfterWrite swaps optimistic pref uri", () => {
    const moved = applyPublicationFolderMoveToProjection(baseProjection, {
      publicationId: publicationRow.publicationId,
      folderId: "folder1",
    });
    const next = reconcilePublicationPrefAfterWrite(
      moved,
      publicationRow.publicationId,
      {
        uri: "at://did:plc:viewer/app.thesocialwire.publicationPrefs/pref1",
        rkey: "pref1",
      }
    );

    expect(next?.publicationPrefs[0]?.uri).toBe(
      "at://did:plc:viewer/app.thesocialwire.publicationPrefs/pref1"
    );
  });
});
