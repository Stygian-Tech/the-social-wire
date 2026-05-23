import { describe, expect, test } from "bun:test";

import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import {
  addOptimisticFolderToProjection,
  createOptimisticFolderRkey,
  removeFolderFromSidebarProjection,
  removeOptimisticFolderFromProjection,
  replaceOptimisticFolderInProjection,
} from "@/lib/optimisticSidebarFolder";

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
  folders: [],
  publicationPrefs: [],
  allPublicationRows: [publicationRow],
  myPublications: [],
  subscribedUnfoldered: [],
  followingTabPublications: [],
  enrollAuthorDids: [],
  refreshedAt: "2026-01-01T00:00:00.000Z",
};

describe("optimisticSidebarFolder", () => {
  test("addOptimisticFolderToProjection appends an empty folder section", () => {
    const optimisticRkey = createOptimisticFolderRkey();
    const next = addOptimisticFolderToProjection(baseProjection, {
      viewerDid: baseProjection.viewerDid,
      rkey: optimisticRkey,
      name: "Tech",
      icon: "💻",
    });

    expect(next?.folders).toHaveLength(1);
    expect(next?.folders[0]?.value.name).toBe("Tech");
    expect(next?.folderSections).toBeUndefined();
  });

  test("addOptimisticFolderToProjection extends existing folder sections", () => {
    const optimisticRkey = createOptimisticFolderRkey();
    const next = addOptimisticFolderToProjection(
      {
        ...baseProjection,
        folderSections: [],
      },
      {
        viewerDid: baseProjection.viewerDid,
        rkey: optimisticRkey,
        name: "Tech",
      }
    );

    const folderUri = next?.folders[0]?.uri;
    expect(folderUri).toBeDefined();
    expect(next?.folderSections).toEqual([
      {
        folderRkey: optimisticRkey,
        folderUri: folderUri!,
        publications: [],
      },
    ]);
  });

  test("replaceOptimisticFolderInProjection swaps temp folder ids", () => {
    const optimisticRkey = createOptimisticFolderRkey();
    const optimistic = addOptimisticFolderToProjection(baseProjection, {
      viewerDid: baseProjection.viewerDid,
      rkey: optimisticRkey,
      name: "Tech",
    });
    const withPref = {
      ...optimistic!,
      folderSections: [
        {
          folderRkey: optimisticRkey,
          folderUri: optimistic!.folders[0]!.uri,
          publications: [],
        },
      ],
      publicationPrefs: [
        {
          uri: "at://did:plc:viewer/com.thesocialwire.publicationPrefs/pref1",
          publicationId: "at://did:plc:author/site.standard.publication/pub1",
          value: { folderId: optimisticRkey },
        },
      ],
    };

    const next = replaceOptimisticFolderInProjection(
      withPref,
      optimisticRkey,
      {
        uri: "at://did:plc:viewer/com.thesocialwire.folder/folder1",
        rkey: "folder1",
      },
      { name: "Tech" }
    );

    expect(next?.folders[0]?.rkey).toBe("folder1");
    expect(next?.folderSections?.[0]?.folderRkey).toBe("folder1");
    expect(next?.publicationPrefs[0]?.value.folderId).toBe("folder1");
  });

  test("removeOptimisticFolderFromProjection rolls back optimistic rows", () => {
    const optimisticRkey = createOptimisticFolderRkey();
    const optimistic = addOptimisticFolderToProjection(baseProjection, {
      viewerDid: baseProjection.viewerDid,
      rkey: optimisticRkey,
      name: "Tech",
    });

    const next = removeOptimisticFolderFromProjection(
      optimistic,
      optimisticRkey
    );

    expect(next?.folders).toEqual([]);
    expect(next?.folderSections).toBeUndefined();
  });

  test("removeFolderFromSidebarProjection restores publications to Publications", () => {
    const projection: PublicationSidebarProjection = {
      ...baseProjection,
      folders: [
        {
          uri: "at://did:plc:viewer/com.thesocialwire.folder/folder1",
          rkey: "folder1",
          value: { name: "Tech" },
        },
      ],
      publicationPrefs: [
        {
          uri: "at://did:plc:viewer/com.thesocialwire.publicationPrefs/pref1",
          publicationId: publicationRow.publicationId,
          value: { folderId: "folder1" },
        },
      ],
      subscribedUnfoldered: [],
      folderSections: [
        {
          folderRkey: "folder1",
          folderUri: "at://did:plc:viewer/com.thesocialwire.folder/folder1",
          publications: [publicationRow],
        },
      ],
    };

    const next = removeFolderFromSidebarProjection(projection, "folder1");

    expect(next?.folders).toEqual([]);
    expect(next?.subscribedUnfoldered).toHaveLength(1);
    expect(next?.publicationPrefs[0]?.value.folderId).toBeUndefined();
  });
});
