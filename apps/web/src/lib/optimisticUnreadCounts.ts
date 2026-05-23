import type { QueryClient } from "@tanstack/react-query";

import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/hooks/usePublicationSidebarData";
import {
  normalizeAtRepoParam,
  type DiscoveredPublication,
} from "@/lib/atprotoClient";
import type {
  PublicationSidebarProjection,
  SidebarPublicationRow,
} from "@/lib/publicationProjectionClient";
import {
  countUnreadCachedEntries,
  getCachedEntriesForPublication,
} from "@/lib/unreadCounts";

function clampUnreadCount(count: number): number {
  return Math.max(0, count);
}

function applyDeltaToCount(current: number | undefined, delta: number): number {
  return clampUnreadCount((current ?? 0) + delta);
}

export function countCachedUnreadForPublication(
  queryClient: QueryClient,
  publicationId: string,
  isEntryRead: (entryId: string) => boolean
): number {
  return countUnreadCachedEntries(
    getCachedEntriesForPublication(queryClient, publicationId),
    isEntryRead
  );
}

export function countCachedReadForPublication(
  queryClient: QueryClient,
  publicationId: string,
  isEntryRead: (entryId: string) => boolean
): number {
  const entries = getCachedEntriesForPublication(queryClient, publicationId);
  const seen = new Set<string>();
  let count = 0;
  for (const entry of entries) {
    if (seen.has(entry.entryId)) continue;
    seen.add(entry.entryId);
    if (isEntryRead(entry.entryId)) count += 1;
  }
  return count;
}

function publicationIdsMatch(a: string, b: string): boolean {
  return normalizeAtRepoParam(a) === normalizeAtRepoParam(b);
}

function patchSidebarRowUnreadCount(
  row: SidebarPublicationRow,
  normalizedPublicationId: string,
  delta: number
): SidebarPublicationRow {
  if (
    !publicationIdsMatch(row.publicationId, normalizedPublicationId) ||
    row.unreadCount == null
  ) {
    return row;
  }
  return {
    ...row,
    unreadCount: applyDeltaToCount(row.unreadCount, delta),
  };
}

function patchProjectionPublicationRows(
  projection: PublicationSidebarProjection,
  normalizedPublicationId: string,
  delta: number
): Pick<
  PublicationSidebarProjection,
  | "allPublicationRows"
  | "subscribedUnfoldered"
  | "followingTabPublications"
  | "myPublications"
  | "folderSections"
> {
  const patchRows = (rows: SidebarPublicationRow[]) =>
    rows.map((row) =>
      patchSidebarRowUnreadCount(row, normalizedPublicationId, delta)
    );

  return {
    allPublicationRows: patchRows(projection.allPublicationRows ?? []),
    subscribedUnfoldered: patchRows(projection.subscribedUnfoldered ?? []),
    followingTabPublications: patchRows(
      projection.followingTabPublications ?? []
    ),
    myPublications: patchRows(projection.myPublications ?? []),
    folderSections: projection.folderSections?.map((section) => ({
      ...section,
      publications: patchRows(section.publications),
    })),
  };
}

export function applyPublicationUnreadCountDelta(
  queryClient: QueryClient,
  viewerDid: string,
  publicationId: string,
  delta: number
): void {
  if (!viewerDid || !publicationId || delta === 0) return;
  const normalizedPublicationId = normalizeAtRepoParam(publicationId);

  queryClient.setQueriesData<Record<string, number>>(
    { queryKey: ["appviewUnreadCounts", viewerDid] },
    (old) => {
      if (!old) return old;
      const next = { ...old };
      const existingKey = Object.keys(next).find((key) =>
        publicationIdsMatch(key, normalizedPublicationId)
      );
      const updated = applyDeltaToCount(
        existingKey ? next[existingKey] : undefined,
        delta
      );
      if (existingKey) delete next[existingKey];
      if (updated === 0) return next;
      next[normalizedPublicationId] = updated;
      return next;
    }
  );

  queryClient.setQueryData<PublicationSidebarProjection>(
    PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid),
    (old) => {
      if (!old) return old;

      const unreadCountsByPublicationId = old.unreadCountsByPublicationId
        ? { ...old.unreadCountsByPublicationId }
        : undefined;

      if (unreadCountsByPublicationId) {
        const existingKey = Object.keys(unreadCountsByPublicationId).find(
          (key) => publicationIdsMatch(key, normalizedPublicationId)
        );
        const updated = applyDeltaToCount(
          existingKey
            ? unreadCountsByPublicationId[existingKey]
            : unreadCountsByPublicationId[normalizedPublicationId],
          delta
        );
        if (existingKey) delete unreadCountsByPublicationId[existingKey];
        if (updated === 0) {
          delete unreadCountsByPublicationId[normalizedPublicationId];
        } else {
          unreadCountsByPublicationId[normalizedPublicationId] = updated;
        }
      }

      return {
        ...old,
        ...patchProjectionPublicationRows(old, normalizedPublicationId, delta),
        unreadCountsByPublicationId,
      };
    }
  );
}

export function applyBulkPublicationUnreadCountDeltas(
  queryClient: QueryClient,
  viewerDid: string,
  deltas: ReadonlyMap<string, number>
): void {
  for (const [publicationId, delta] of deltas) {
    applyPublicationUnreadCountDelta(queryClient, viewerDid, publicationId, delta);
  }
}

export function bulkReadDeltasForPublications(
  queryClient: QueryClient,
  publications: DiscoveredPublication[],
  isEntryRead: (entryId: string) => boolean
): Map<string, number> {
  const deltas = new Map<string, number>();
  for (const pub of publications) {
    const unread = countCachedUnreadForPublication(
      queryClient,
      pub.publicationId,
      isEntryRead
    );
    if (unread > 0) {
      deltas.set(pub.publicationId, -unread);
    }
  }
  return deltas;
}

export function bulkUnreadDeltasForPublications(
  queryClient: QueryClient,
  publications: DiscoveredPublication[],
  isEntryRead: (entryId: string) => boolean
): Map<string, number> {
  const deltas = new Map<string, number>();
  for (const pub of publications) {
    const read = countCachedReadForPublication(
      queryClient,
      pub.publicationId,
      isEntryRead
    );
    if (read > 0) {
      deltas.set(pub.publicationId, read);
    }
  }
  return deltas;
}
