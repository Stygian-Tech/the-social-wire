import {
  type InfiniteData,
  type QueryClient,
} from "@tanstack/react-query";

import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type { EntriesPage } from "@/hooks/useEntries";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { publicationIdsMatch } from "@/lib/publicationSubscriptionMatch";

function excludesPublication(
  row: { publicationId: string },
  publicationId: string,
): boolean {
  return !publicationIdsMatch(row.publicationId, publicationId);
}

/** Immediately removes an unsubscribed publication from every rendered sidebar section. */
export function removePublicationFromSidebarProjection(
  projection: PublicationSidebarProjection | undefined,
  publicationId: string,
): PublicationSidebarProjection | undefined {
  if (!projection) return undefined;

  const unreadCountsByPublicationId = projection.unreadCountsByPublicationId
    ? Object.fromEntries(
        Object.entries(projection.unreadCountsByPublicationId).filter(
          ([key]) => !publicationIdsMatch(key, publicationId),
        ),
      )
    : undefined;

  return {
    ...projection,
    allPublicationRows: projection.allPublicationRows.filter((row) =>
      excludesPublication(row, publicationId),
    ),
    myPublications: projection.myPublications.filter((row) =>
      excludesPublication(row, publicationId),
    ),
    subscribedUnfoldered: projection.subscribedUnfoldered.filter((row) =>
      excludesPublication(row, publicationId),
    ),
    followingTabPublications: projection.followingTabPublications.filter(
      (row) => excludesPublication(row, publicationId),
    ),
    folderSections: projection.folderSections?.map((section) => ({
      ...section,
      publications: section.publications.filter((row) =>
        excludesPublication(row, publicationId),
      ),
    })),
    ...(unreadCountsByPublicationId
      ? { unreadCountsByPublicationId }
      : {}),
  };
}

/** Removes publication pages and strips its rows from every persisted aggregate feed cache. */
export function removePublicationFromEntryCaches(
  queryClient: QueryClient,
  viewerDid: string,
  publication: DiscoveredPublication,
): void {
  const publicationId = publication.publicationId;

  queryClient.removeQueries({
    predicate: ({ queryKey }) =>
      queryKey[0] === "entries" &&
      queryKey[1] === viewerDid &&
      typeof queryKey[2] === "string" &&
      publicationIdsMatch(queryKey[2], publicationId),
  });

  const aggregateQueries =
    queryClient.getQueriesData<InfiniteData<EntriesPage>>({
      predicate: ({ queryKey }) =>
        queryKey[0] === "aggregateEntries" && queryKey[1] === viewerDid,
    });

  for (const [queryKey, data] of aggregateQueries) {
    if (!data) continue;
    queryClient.setQueryData<InfiniteData<EntriesPage>>(queryKey, {
      ...data,
      pages: data.pages.map((page) => ({
        ...page,
        entries: page.entries.filter(
          (entry) =>
            !entry.publicationId ||
            !publicationIdsMatch(entry.publicationId, publicationId),
        ),
      })),
    });
  }
}
