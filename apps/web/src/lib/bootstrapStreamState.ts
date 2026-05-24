import type { QueryClient } from "@tanstack/react-query";

import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import type { ParsedBootstrapStreamEvent } from "@/lib/bootstrapStreamModels";
import { dedupeEntryListItems } from "@/lib/rssFeedCore";
import {
  mergeSidebarProjections,
  publicationIdsFromProjection,
  sidebarPublicationRows,
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
  counts: Record<string, number>,
  options?: { replacePublicationIds?: readonly string[] }
): PublicationSidebarProjection {
  const unreadCountsByPublicationId = {
    ...(projection.unreadCountsByPublicationId ?? {}),
    ...counts,
  };

  if (options?.replacePublicationIds?.length) {
    for (const publicationId of options.replacePublicationIds) {
      const fresh = counts[publicationId] ?? 0;
      if (fresh <= 0) {
        delete unreadCountsByPublicationId[publicationId];
      } else {
        unreadCountsByPublicationId[publicationId] = fresh;
      }
    }
  }

  const applyRow = (
    row: PublicationSidebarProjection["allPublicationRows"][number]
  ) => {
    if (options?.replacePublicationIds?.includes(row.publicationId)) {
      const count = counts[row.publicationId] ?? 0;
      return { ...row, unreadCount: count > 0 ? count : 0 };
    }
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
  const merged = mergeSidebarProjections(projection, {
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

  const counts: Record<string, number> = {};
  for (const row of sidebarPublicationRows(merged)) {
    if (row.unreadCount != null && row.unreadCount > 0) {
      counts[row.publicationId] = row.unreadCount;
    }
  }

  return Object.keys(counts).length > 0
    ? applyUnreadCountsEvent(merged, counts)
    : merged;
}

export function writeStreamedEntriesPage(
  queryClient: QueryClient,
  payload: { publicationId: string; entries: EntriesPage["entries"]; cursor?: string },
  articleFilter: "all" | "unread" = "all"
): void {
  const publicationKey = normalizeAtRepoParam(payload.publicationId);
  const page: EntriesPage = {
    entries: dedupeEntryListItems(payload.entries),
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
        projection = applyUnreadCountsEvent(
          projection,
          args.event.payload.counts,
          { replacePublicationIds: publicationIdsFromProjection(projection) }
        );
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
