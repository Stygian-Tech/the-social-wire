import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";

const MAX_PERSISTED_PUBLICATION_ROWS = 250;

/** Persist completed sidebar snapshots, including empty folder/publication lists. */
export function shouldPersistSidebarProjection(
  data: PublicationSidebarProjection | undefined
): boolean {
  if (
    !data?.viewerDid ||
    typeof data.refreshedAt !== "string" ||
    data.refreshedAt.trim().length === 0
  ) {
    return false;
  }
  return data.allPublicationRows.length <= MAX_PERSISTED_PUBLICATION_ROWS;
}
