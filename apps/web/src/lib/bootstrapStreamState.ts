import type { QueryClient } from "@tanstack/react-query";

import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import type { ParsedBootstrapStreamEvent } from "@/lib/bootstrapStreamModels";
import { dedupeEntryListItems } from "@/lib/rssFeedCore";
import {
  mergeSidebarProjections,
  publicationIdsFromProjection,
  type PublicationSidebarProjection,
  type UnreadCountsAccuracy,
} from "@/lib/publicationProjectionClient";
import {
  ENTRIES_QUERY_KEY,
  ENTRIES_QUERY_STALE_MS,
  type EntriesPage,
} from "@/hooks/useEntries";

type SidebarRow = PublicationSidebarProjection["allPublicationRows"][number];
type SidebarSectionPayload = Extract<
  ParsedBootstrapStreamEvent,
  { kind: "sidebarSection" }
>["payload"];
type UnreadCountsEventOptions = {
  replacePublicationIds?: readonly string[];
  generation?: number;
  accuracy?: UnreadCountsAccuracy;
  countedAt?: string;
};

function normalizedPublicationId(publicationId: string): string {
  return normalizeAtRepoParam(publicationId);
}

function countForPublicationId(
  counts: Record<string, number>,
  publicationId: string
): number | undefined {
  const exact = counts[publicationId];
  if (exact != null) return exact;
  return counts[normalizedPublicationId(publicationId)];
}

function countAccuracyRank(accuracy: UnreadCountsAccuracy | undefined): number {
  if (accuracy === "exact") return 2;
  if (accuracy === "estimated") return 1;
  return 0;
}

function shouldApplyUnreadCountsEvent(
  projection: PublicationSidebarProjection,
  options: UnreadCountsEventOptions | undefined
): boolean {
  const incomingGeneration = options?.generation;
  if (incomingGeneration == null) return true;

  const currentGeneration = projection.unreadCountsGeneration;
  if (currentGeneration != null && incomingGeneration < currentGeneration) {
    return false;
  }

  if (currentGeneration === incomingGeneration) {
    return (
      countAccuracyRank(options?.accuracy) >=
      countAccuracyRank(projection.unreadCountsAccuracy)
    );
  }

  return true;
}

export function applySidebarPriorityEvent(
  current: PublicationSidebarProjection | undefined,
  payload: PublicationSidebarProjection
): PublicationSidebarProjection {
  if (!current) return payload;

  const priorityRowsById = new Map<string, SidebarRow>();
  const addPriorityRow = (row: SidebarRow) => {
    priorityRowsById.set(normalizeAtRepoParam(row.publicationId), row);
  };

  for (const row of payload.allPublicationRows) addPriorityRow(row);
  for (const row of payload.myPublications) addPriorityRow(row);
  for (const row of payload.subscribedUnfoldered) addPriorityRow(row);
  for (const row of payload.followingTabPublications) addPriorityRow(row);
  for (const section of payload.folderSections ?? []) {
    for (const row of section.publications) addPriorityRow(row);
  }

  const mergeRow = (row: SidebarRow) => {
    const priority = priorityRowsById.get(
      normalizeAtRepoParam(row.publicationId)
    );
    if (!priority) return row;
    return {
      ...row,
      ...priority,
      unreadCount: priority.unreadCount ?? row.unreadCount,
    };
  };

  const appendNewPriorityRows = (rows: SidebarRow[]) => {
    const seen = new Set(
      rows.map((row) => normalizeAtRepoParam(row.publicationId))
    );
    const merged = rows.map(mergeRow);
    for (const row of payload.allPublicationRows) {
      const key = normalizeAtRepoParam(row.publicationId);
      if (seen.has(key)) continue;
      seen.add(key);
      merged.push(row);
    }
    return merged;
  };

  const mergeList = (
    currentRows: SidebarRow[],
    priorityRows: SidebarRow[]
  ) => {
    const seen = new Set(
      currentRows.map((row) => normalizeAtRepoParam(row.publicationId))
    );
    const merged = currentRows.map(mergeRow);
    for (const row of priorityRows) {
      const key = normalizeAtRepoParam(row.publicationId);
      if (seen.has(key)) continue;
      seen.add(key);
      merged.push(row);
    }
    return merged;
  };

  const unreadCountsByPublicationId = {
    ...(current.unreadCountsByPublicationId ?? {}),
    ...(payload.unreadCountsByPublicationId ?? {}),
  };

  return {
    ...current,
    refreshedAt: payload.refreshedAt,
    allPublicationRows: appendNewPriorityRows(current.allPublicationRows),
    myPublications: mergeList(current.myPublications, payload.myPublications),
    subscribedUnfoldered: mergeList(
      current.subscribedUnfoldered,
      payload.subscribedUnfoldered
    ),
    followingTabPublications: mergeList(
      current.followingTabPublications,
      payload.followingTabPublications
    ),
    folderSections: current.folderSections?.map((section) => ({
      ...section,
      publications: section.publications.map(mergeRow),
    })),
    enrollAuthorDids: [
      ...new Set([...current.enrollAuthorDids, ...payload.enrollAuthorDids]),
    ],
    unreadCountsByPublicationId,
  };
}

export function applyUnreadCountsEvent(
  projection: PublicationSidebarProjection,
  counts: Record<string, number>,
  options?: UnreadCountsEventOptions
): PublicationSidebarProjection {
  if (!shouldApplyUnreadCountsEvent(projection, options)) {
    return projection;
  }

  const unreadCountsByPublicationId = {
    ...(projection.unreadCountsByPublicationId ?? {}),
    ...counts,
  };

  const replacePublicationIds = options?.replacePublicationIds ?? [];
  const replaceSet = new Set(replacePublicationIds.map(normalizedPublicationId));

  if (replacePublicationIds.length) {
    for (const publicationId of replacePublicationIds) {
      const fresh = countForPublicationId(counts, publicationId) ?? 0;
      unreadCountsByPublicationId[publicationId] = Math.max(0, fresh);
    }
  }

  const applyRow = (
    row: PublicationSidebarProjection["allPublicationRows"][number]
  ) => {
    if (replaceSet.has(normalizedPublicationId(row.publicationId))) {
      const count = countForPublicationId(counts, row.publicationId) ?? 0;
      const unreadCount = count > 0 ? count : 0;
      return row.unreadCount === unreadCount ? row : { ...row, unreadCount };
    }
    const count = countForPublicationId(counts, row.publicationId);
    if (count == null) return row;
    return row.unreadCount === count ? row : { ...row, unreadCount: count };
  };

  const applyRows = (rows: SidebarRow[]) => {
    let changed = false;
    const next = rows.map((row) => {
      const updated = applyRow(row);
      if (updated !== row) changed = true;
      return updated;
    });
    return changed ? next : rows;
  };

  return {
    ...projection,
    unreadCountsGeneration:
      options?.generation ?? projection.unreadCountsGeneration,
    unreadCountsAccuracy:
      options?.accuracy ?? projection.unreadCountsAccuracy,
    unreadCountsCountedAt:
      options?.countedAt ?? projection.unreadCountsCountedAt,
    unreadCountsByPublicationId,
    allPublicationRows: applyRows(projection.allPublicationRows),
    myPublications: applyRows(projection.myPublications),
    subscribedUnfoldered: applyRows(projection.subscribedUnfoldered),
    followingTabPublications: applyRows(projection.followingTabPublications),
    folderSections: projection.folderSections?.map((section) => {
      const publications = applyRows(section.publications);
      return publications === section.publications
        ? section
        : { ...section, publications };
    }),
  };
}

function mergeSectionRow(
  incoming: SidebarRow,
  existing: SidebarRow | undefined,
  unreadCounts: Record<string, number> | undefined
): SidebarRow {
  const unreadCount =
    unreadCounts == null
      ? incoming.unreadCount ?? existing?.unreadCount
      : Math.max(0, countForPublicationId(unreadCounts, incoming.publicationId) ?? 0);

  const merged: SidebarRow = {
    ...(existing ?? incoming),
    ...incoming,
    unreadCount,
  };

  if (
    existing &&
    existing === incoming &&
    existing.unreadCount === merged.unreadCount
  ) {
    return existing;
  }
  if (
    existing &&
    existing.publicationId === merged.publicationId &&
    existing.title === merged.title &&
    existing.iconUrl === merged.iconUrl &&
    existing.avatarUrl === merged.avatarUrl &&
    existing.unreadCount === merged.unreadCount
  ) {
    return existing;
  }
  return merged;
}

function sectionMatchesPayload(
  section: NonNullable<PublicationSidebarProjection["folderSections"]>[number],
  payload: SidebarSectionPayload
): boolean {
  return (
    (!!payload.folderRkey && section.folderRkey === payload.folderRkey) ||
    (!!payload.folderUri && section.folderUri === payload.folderUri) ||
    `folder:${section.folderRkey}` === payload.sectionKey
  );
}

export function applySidebarSectionEvent(
  projection: PublicationSidebarProjection,
  payload: SidebarSectionPayload
): PublicationSidebarProjection {
  const existingSectionGeneration =
    projection.sidebarSectionGenerations?.[payload.sectionKey];
  if (
    payload.sectionGeneration != null &&
    existingSectionGeneration != null &&
    payload.sectionGeneration < existingSectionGeneration
  ) {
    return projection;
  }

  const existingRowsById = new Map<string, SidebarRow>();
  for (const row of projection.allPublicationRows) {
    existingRowsById.set(normalizedPublicationId(row.publicationId), row);
  }
  for (const section of projection.folderSections ?? []) {
    for (const row of section.publications) {
      existingRowsById.set(normalizedPublicationId(row.publicationId), row);
    }
  }

  const incomingRowsById = new Map<string, SidebarRow>();
  for (const row of payload.publications) {
    const key = normalizedPublicationId(row.publicationId);
    incomingRowsById.set(
      key,
      mergeSectionRow(row, existingRowsById.get(key), payload.unreadCounts)
    );
  }

  const replaceIds = payload.replacePublicationIds?.length
    ? payload.replacePublicationIds
    : payload.publications.map((row) => row.publicationId);
  const replaceSet = new Set(replaceIds.map(normalizedPublicationId));

  const allPublicationRows = projection.allPublicationRows.map((row) => {
    const key = normalizedPublicationId(row.publicationId);
    if (!replaceSet.has(key)) return row;
    return incomingRowsById.get(key) ?? row;
  });
  const seenAllRows = new Set(allPublicationRows.map((row) => normalizedPublicationId(row.publicationId)));
  for (const row of incomingRowsById.values()) {
    const key = normalizedPublicationId(row.publicationId);
    if (seenAllRows.has(key)) continue;
    seenAllRows.add(key);
    allPublicationRows.push(row);
  }

  let foundSection = false;
  const folderSections = (projection.folderSections ?? []).map((section) => {
    if (!sectionMatchesPayload(section, payload)) return section;
    foundSection = true;
    return {
      ...section,
      folderRkey: payload.folderRkey ?? section.folderRkey,
      folderUri: payload.folderUri ?? section.folderUri,
      publications: payload.publications.map((row) => {
        const key = normalizedPublicationId(row.publicationId);
        return incomingRowsById.get(key) ?? row;
      }),
    };
  });

  if (!foundSection && payload.folderRkey && payload.folderUri) {
    folderSections.push({
      folderRkey: payload.folderRkey,
      folderUri: payload.folderUri,
      publications: payload.publications.map((row) => {
        const key = normalizedPublicationId(row.publicationId);
        return incomingRowsById.get(key) ?? row;
      }),
    });
  }

  const nextProjection: PublicationSidebarProjection = {
    ...projection,
    refreshedAt: payload.refreshedAt,
    allPublicationRows,
    folderSections,
    sidebarSectionGenerations:
      payload.sectionGeneration == null
        ? projection.sidebarSectionGenerations
        : {
            ...(projection.sidebarSectionGenerations ?? {}),
            [payload.sectionKey]: payload.sectionGeneration,
          },
  };

  if (!payload.unreadCounts) return nextProjection;
  return applyUnreadCountsEvent(nextProjection, payload.unreadCounts, {
    replacePublicationIds: replaceIds,
  });
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
  viewerDid: string,
  payload: { publicationId: string; entries: EntriesPage["entries"]; cursor?: string },
  articleFilter: "all" | "unread" = "all"
): void {
  const publicationKey = normalizeAtRepoParam(payload.publicationId);
  const page: EntriesPage = {
    entries: dedupeEntryListItems(payload.entries),
    cursor: payload.cursor,
  };
  queryClient.setQueryData(
    [...ENTRIES_QUERY_KEY(viewerDid, publicationKey), articleFilter] as const,
    {
      pages: [page],
      pageParams: [undefined],
    }
  );
  queryClient.setQueryDefaults(
    [...ENTRIES_QUERY_KEY(viewerDid, publicationKey), articleFilter] as const,
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
    case "sidebarSection":
      if (projection) {
        projection = applySidebarSectionEvent(projection, args.event.payload);
      }
      break;
    case "unreadCounts":
      if (projection) {
        projection = applyUnreadCountsEvent(
          projection,
          args.event.payload.counts,
          {
            replacePublicationIds:
              args.event.payload.replacePublicationIds ??
              publicationIdsFromProjection(projection),
            generation: args.event.payload.generation,
            accuracy: args.event.payload.accuracy,
            countedAt: args.event.payload.countedAt,
          }
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
