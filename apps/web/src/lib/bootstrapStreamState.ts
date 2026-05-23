import type { QueryClient } from "@tanstack/react-query";

import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import type { ParsedBootstrapStreamEvent } from "@/lib/bootstrapStreamModels";
import {
  mergeSidebarProjections,
  type PublicationSidebarProjection,
} from "@/lib/publicationProjectionClient";
import {
  ENTRIES_QUERY_KEY,
  ENTRIES_QUERY_STALE_MS,
  type EntriesPage,
} from "@/hooks/useEntries";

export function applySidebarPriorityEvent(
  _current: PublicationSidebarProjection | undefined,
  payload: PublicationSidebarProjection
): PublicationSidebarProjection {
  return payload;
}

export function applyUnreadCountsEvent(
  projection: PublicationSidebarProjection,
  counts: Record<string, number>
): PublicationSidebarProjection {
  const unreadCountsByPublicationId = {
    ...(projection.unreadCountsByPublicationId ?? {}),
    ...counts,
  };
  const applyRow = (
    row: PublicationSidebarProjection["allPublicationRows"][number]
  ) => {
    const count = counts[row.publicationId];
    if (count == null) return row;
    return { ...row, unreadCount: count };
  };

  return {
    ...projection,
    unreadCountsByPublicationId,
    allPublicationRows: projection.allPublicationRows.map(applyRow),
    myPublications: projection.myPublications.map(applyRow),
    subscribedUnfoldered: projection.subscribedUnfoldered.map(applyRow),
    followingTabPublications: projection.followingTabPublications.map(applyRow),
    folderSections: projection.folderSections?.map((section) => ({
      ...section,
      publications: section.publications.map(applyRow),
    })),
  };
}

export function applySidebarFoldersEvent(
  projection: PublicationSidebarProjection,
  payload: {
    folderSections: NonNullable<PublicationSidebarProjection["folderSections"]>;
    allPublicationRows: PublicationSidebarProjection["allPublicationRows"];
  }
): PublicationSidebarProjection {
  return mergeSidebarProjections(projection, {
    ...projection,
    folderSections: payload.folderSections,
    allPublicationRows: payload.allPublicationRows,
    folders: [],
    publicationPrefs: [],
    myPublications: [],
    subscribedUnfoldered: [],
    followingTabPublications: [],
    enrollAuthorDids: [],
    refreshedAt: projection.refreshedAt,
  });
}

export function writeStreamedEntriesPage(
  queryClient: QueryClient,
  payload: { publicationId: string; entries: EntriesPage["entries"]; cursor?: string },
  articleFilter: "all" | "unread" = "all"
): void {
  const publicationKey = normalizeAtRepoParam(payload.publicationId);
  const page: EntriesPage = {
    entries: payload.entries,
    cursor: payload.cursor,
  };
  queryClient.setQueryData(
    [...ENTRIES_QUERY_KEY(publicationKey), articleFilter] as const,
    {
      pages: [page],
      pageParams: [undefined],
    }
  );
  queryClient.setQueryDefaults(
    [...ENTRIES_QUERY_KEY(publicationKey), articleFilter] as const,
    { staleTime: ENTRIES_QUERY_STALE_MS }
  );
}

export function applyBootstrapStreamEvent(args: {
  projection: PublicationSidebarProjection | undefined;
  event: ParsedBootstrapStreamEvent;
}): {
  projection: PublicationSidebarProjection | undefined;
  selectedPublicationId: string | null;
  streamError: string | null;
  streamDone: boolean;
} {
  let { projection } = args;
  let selectedPublicationId: string | null = null;
  let streamError: string | null = null;
  let streamDone = false;

  switch (args.event.kind) {
    case "sidebarPriority":
      projection = applySidebarPriorityEvent(projection, args.event.payload);
      break;
    case "unreadCounts":
      if (projection) {
        projection = applyUnreadCountsEvent(projection, args.event.payload.counts);
      }
      break;
    case "selectedPublication":
      selectedPublicationId = args.event.payload.publicationId;
      break;
    case "sidebarFolders":
      if (projection) {
        projection = applySidebarFoldersEvent(projection, args.event.payload);
      }
      break;
    case "error":
      streamError = args.event.payload.message;
      break;
    case "done":
      streamDone = true;
      break;
    case "warning":
    case "entriesPage":
      break;
  }

  return { projection, selectedPublicationId, streamError, streamDone };
}
