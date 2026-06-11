import type { useFolders } from "@/hooks/useFolders";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import {
  sidebarRowToDiscoveredPublication,
  unreadCountsMapFromProjection,
  type PublicationSidebarProjection,
} from "@/lib/publicationProjectionClient";
import {
  COLLECTION_PUB_PREFS,
  type PublicationPrefsRecord,
  type RepoRecord,
} from "@/lib/pdsClient";

function prefsRecordFromProjection(
  row: PublicationSidebarProjection["publicationPrefs"][number]
): RepoRecord<PublicationPrefsRecord> {
  const raw = row.value;
  const folderId =
    typeof raw.folderId === "string" ? raw.folderId : undefined;
  const sortOrder =
    typeof raw.sortOrder === "number" ? raw.sortOrder : undefined;
  const hidden = typeof raw.hidden === "boolean" ? raw.hidden : undefined;
  const createdAt =
    typeof raw.createdAt === "string"
      ? raw.createdAt
      : new Date().toISOString();

  return {
    uri: row.uri,
    cid: typeof raw.cid === "string" ? raw.cid : "",
    value: {
      $type: COLLECTION_PUB_PREFS,
      publicationId: row.publicationId,
      folderId,
      sortOrder,
      hidden,
      createdAt,
    },
  };
}

export type SidebarProjectionState = {
  folders: ReturnType<typeof useFolders>["data"];
  prefsMap: Map<string, RepoRecord<PublicationPrefsRecord>>;
  allPublicationRows: DiscoveredPublication[];
  sidebarRowsById: Map<string, PublicationSidebarProjection["allPublicationRows"][number]>;
  folderMap: Map<string, DiscoveredPublication[]>;
  myPublications: DiscoveredPublication[];
  unfolderedPubs: DiscoveredPublication[];
  followingTabPublications: DiscoveredPublication[];
  enrollAuthorDids: string[];
  unreadCountsByPublicationId: Map<string, number>;
};

/** Derive sidebar list state from a server projection DTO. */
export function projectionToSidebarState(
  projection: PublicationSidebarProjection
): SidebarProjectionState {
  const prefsMap = new Map(
    projection.publicationPrefs.map((p) => [
      p.publicationId,
      prefsRecordFromProjection(p),
    ] as const)
  );

  const folderMap = new Map<string, DiscoveredPublication[]>();

  if (projection.folderSections?.length) {
    for (const section of projection.folderSections) {
      folderMap.set(
        section.folderRkey,
        section.publications.map(sidebarRowToDiscoveredPublication)
      );
    }
  } else {
    const myIds = new Set(
      projection.myPublications.map((m) => m.publicationId)
    );
    const followingIds = new Set(
      projection.followingTabPublications.map((f) => f.publicationId)
    );

    for (const row of projection.allPublicationRows) {
      const pub = sidebarRowToDiscoveredPublication(row);
      if (myIds.has(pub.publicationId) || followingIds.has(pub.publicationId)) {
        continue;
      }
      const pref = prefsMap.get(pub.publicationId);
      const folderId = pref?.value.folderId;
      if (!folderId) continue;
      const list = folderMap.get(folderId) ?? [];
      list.push(pub);
      folderMap.set(folderId, list);
    }
  }

  const subscribed = projection.subscribedUnfoldered.map(
    sidebarRowToDiscoveredPublication
  );
  const myPublications = projection.myPublications.map(
    sidebarRowToDiscoveredPublication
  );

  return {
    folders: projection.folders as unknown as ReturnType<typeof useFolders>["data"],
    prefsMap,
    allPublicationRows: projection.allPublicationRows.map(
      sidebarRowToDiscoveredPublication
    ),
    sidebarRowsById: new Map(
      projection.allPublicationRows.map((r) => [r.publicationId, r] as const)
    ),
    folderMap,
    myPublications,
    unfolderedPubs: subscribed,
    followingTabPublications: projection.followingTabPublications.map(
      sidebarRowToDiscoveredPublication
    ),
    enrollAuthorDids: projection.enrollAuthorDids,
    unreadCountsByPublicationId: unreadCountsMapFromProjection(projection),
  };
}

/** Show skeleton sub-rows when cold-loading without a cached snapshot. */
export function sidebarListShowsSkeleton(args: {
  hasSidebarSnapshot: boolean;
  isRestoring: boolean;
  sidebarFetching: boolean;
  itemCount: number;
}): boolean {
  return (
    !args.hasSidebarSnapshot &&
    !args.isRestoring &&
    args.sidebarFetching &&
    args.itemCount === 0
  );
}
