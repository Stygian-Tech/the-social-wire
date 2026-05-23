import { COLLECTION_FOLDER } from "@/lib/pdsClient";
import type {
  PublicationSidebarProjection,
  SidebarPublicationRow,
} from "@/lib/publicationProjectionClient";

export const OPTIMISTIC_FOLDER_RKEY_PREFIX = "optimistic-folder-";

export function createOptimisticFolderRkey(): string {
  return `${OPTIMISTIC_FOLDER_RKEY_PREFIX}${crypto.randomUUID()}`;
}

export function isOptimisticFolderRkey(rkey: string): boolean {
  return rkey.startsWith(OPTIMISTIC_FOLDER_RKEY_PREFIX);
}

export function buildSidebarFolderEntry(args: {
  viewerDid: string;
  uri: string;
  rkey: string;
  name: string;
  icon?: string;
  iconImage?: string;
  sortOrder?: number;
  createdAt?: string;
}): PublicationSidebarProjection["folders"][number] {
  const createdAt = args.createdAt ?? new Date().toISOString();
  return {
    uri: args.uri,
    rkey: args.rkey,
    value: {
      $type: COLLECTION_FOLDER,
      name: args.name,
      sortOrder: args.sortOrder ?? 0,
      ...(args.icon ? { icon: args.icon } : {}),
      ...(args.iconImage ? { iconImage: args.iconImage } : {}),
      createdAt,
    },
  };
}

function nextFolderSortOrder(
  projection: PublicationSidebarProjection
): number {
  let max = -1;
  for (const folder of projection.folders) {
    const sortOrder = folder.value.sortOrder;
    if (typeof sortOrder === "number" && sortOrder > max) {
      max = sortOrder;
    }
  }
  return max + 1;
}

export function addOptimisticFolderToProjection(
  projection: PublicationSidebarProjection | undefined,
  args: {
    viewerDid: string;
    rkey: string;
    name: string;
    icon?: string;
    iconImage?: string;
  }
): PublicationSidebarProjection | undefined {
  if (!projection) return undefined;

  const folder = buildSidebarFolderEntry({
    viewerDid: args.viewerDid,
    uri: `at://${args.viewerDid}/${COLLECTION_FOLDER}/${args.rkey}`,
    rkey: args.rkey,
    name: args.name,
    icon: args.icon,
    iconImage: args.iconImage,
    sortOrder: nextFolderSortOrder(projection),
  });

  const folders = [...projection.folders, folder];
  const folderSections = projection.folderSections
    ? [
        ...projection.folderSections,
        {
          folderRkey: folder.rkey,
          folderUri: folder.uri,
          publications: [],
        },
      ]
    : projection.folderSections;

  return {
    ...projection,
    folders,
    folderSections,
  };
}

export function replaceOptimisticFolderInProjection(
  projection: PublicationSidebarProjection | undefined,
  optimisticRkey: string,
  created: { uri: string; rkey: string },
  params: { name: string; icon?: string; iconImage?: string }
): PublicationSidebarProjection | undefined {
  if (!projection) return undefined;

  const index = projection.folders.findIndex(
    (folder) => folder.rkey === optimisticRkey
  );
  if (index < 0) return projection;

  const existing = projection.folders[index];
  const createdAt =
    typeof existing.value.createdAt === "string"
      ? existing.value.createdAt
      : new Date().toISOString();
  const sortOrder =
    typeof existing.value.sortOrder === "number"
      ? existing.value.sortOrder
      : 0;

  const folder = buildSidebarFolderEntry({
    viewerDid: projection.viewerDid,
    uri: created.uri,
    rkey: created.rkey,
    name: params.name,
    icon: params.icon,
    iconImage: params.iconImage,
    sortOrder,
    createdAt,
  });

  const folders = [...projection.folders];
  folders[index] = folder;

  const folderSections = projection.folderSections?.map((section) =>
    section.folderRkey === optimisticRkey
      ? {
          ...section,
          folderRkey: created.rkey,
          folderUri: created.uri,
        }
      : section
  );

  const publicationPrefs = projection.publicationPrefs.map((pref) => {
    const folderId =
      typeof pref.value.folderId === "string" ? pref.value.folderId : undefined;
    if (folderId !== optimisticRkey) return pref;
    return {
      ...pref,
      value: {
        ...pref.value,
        folderId: created.rkey,
      },
    };
  });

  return {
    ...projection,
    folders,
    folderSections,
    publicationPrefs,
  };
}

export function removeOptimisticFolderFromProjection(
  projection: PublicationSidebarProjection | undefined,
  optimisticRkey: string
): PublicationSidebarProjection | undefined {
  if (!projection) return undefined;
  return removeFolderFromSidebarProjection(projection, optimisticRkey);
}

function publicationsInFolderSection(
  projection: PublicationSidebarProjection,
  folderRkey: string
): SidebarPublicationRow[] {
  const section = projection.folderSections?.find(
    (entry) => entry.folderRkey === folderRkey
  );
  if (section) return section.publications;

  const excluded = new Set([
    ...projection.myPublications.map((row) => row.publicationId),
    ...projection.followingTabPublications.map((row) => row.publicationId),
  ]);
  const rows: SidebarPublicationRow[] = [];

  for (const pref of projection.publicationPrefs) {
    const folderId =
      typeof pref.value.folderId === "string" ? pref.value.folderId : undefined;
    if (folderId !== folderRkey) continue;
    const row = projection.allPublicationRows.find(
      (entry) => entry.publicationId === pref.publicationId
    );
    if (!row || excluded.has(row.publicationId)) continue;
    rows.push(row);
  }

  return rows;
}

export function removeFolderFromSidebarProjection(
  projection: PublicationSidebarProjection | undefined,
  folderRkey: string
): PublicationSidebarProjection | undefined {
  if (!projection) return undefined;

  const restoredPublications = publicationsInFolderSection(
    projection,
    folderRkey
  );
  const restoredIds = new Set(
    restoredPublications.map((row) => row.publicationId)
  );
  const subscribedUnfoldered = [
    ...projection.subscribedUnfoldered.filter(
      (row) => !restoredIds.has(row.publicationId)
    ),
    ...restoredPublications,
  ];

  const publicationPrefs = projection.publicationPrefs.map((pref) => {
    const folderId =
      typeof pref.value.folderId === "string" ? pref.value.folderId : undefined;
    if (folderId !== folderRkey) return pref;
    const nextValue = { ...pref.value };
    delete nextValue.folderId;
    return { ...pref, value: nextValue };
  });

  return {
    ...projection,
    folders: projection.folders.filter((folder) => folder.rkey !== folderRkey),
    folderSections: projection.folderSections?.filter(
      (section) => section.folderRkey !== folderRkey
    ),
    subscribedUnfoldered,
    publicationPrefs,
  };
}
