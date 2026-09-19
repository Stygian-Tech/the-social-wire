import type { QueryClient } from "@tanstack/react-query";
import type { OutboxState } from "@thesocialwire/read-state";

/** Local outbox order preserves user intent until its complete manifest is confirmed. */
export function pendingReadStateOverlay(snapshot: OutboxState | undefined, viewerDid?: string): ReadonlyMap<string, boolean> {
  const overlay = new Map<string, boolean>();
  if (!viewerDid || snapshot?.viewerDid !== viewerDid) return overlay;
  for (const entry of snapshot.entries) {
    // Boundary previews are validated by the server against the frozen selection.
    // Unknown entries keep their existing server state; clients never infer membership.
    const subjects = entry.intent.selection === "exact" ? entry.intent.subjectUris : entry.previewSubjectUris ?? [];
    for (const subject of subjects) overlay.set(subject, entry.intent.state === "read");
  }
  return overlay;
}

export function effectiveEntryReadState(entryId: string, serverIsRead: boolean | undefined,
  locallyRead: (entryId: string) => boolean, pending?: (entryId: string) => boolean | undefined): boolean {
  return pending?.(entryId) ?? (serverIsRead === true || locallyRead(entryId));
}

/** Inactive unread feeds opt out of mount refetch and must not survive confirmation. */
export async function invalidateConfirmedReadStateQueries(queryClient: QueryClient, viewerDid: string): Promise<void> {
  const viewerFeed = ({ queryKey }: { queryKey: readonly unknown[] }) => queryKey[1] === viewerDid
    && ["entries", "aggregateEntries"].includes(String(queryKey[0]));
  queryClient.removeQueries({ type: "inactive", predicate: query => viewerFeed(query) && query.queryKey.at(-1) === "unread" });
  await queryClient.invalidateQueries({ predicate: query => viewerFeed(query)
    || (query.queryKey[0] === "publicationSidebarProjection" && query.queryKey.includes(viewerDid)) });
}
