import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { QueryClient } from "@tanstack/react-query";

import { awaitWithAbort } from "@/lib/awaitWithAbort";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import {
  sidebarPublicationRows,
  type PublicationSidebarProjection,
  type SidebarPublicationRow,
} from "@/lib/publicationProjectionClient";
import { enrollAuthorsInAppView } from "@/lib/thinAppViewClient";

/** Match the visible feed; a publication refresh must not enroll the full follow graph. */
export function readerRefreshRows(client: QueryClient, did: string, projection: PublicationSidebarProjection): SidebarPublicationRow[] {
  const all = sidebarPublicationRows(projection);
  const selected = new Map<string, SidebarPublicationRow>();
  const add = (rows: SidebarPublicationRow[]) => rows.forEach(row => selected.set(row.publicationId, row));
  for (const query of client.getQueryCache().findAll({ predicate: query => query.isActive() && query.queryKey[1] === did })) {
    const [kind, , scope, id] = query.queryKey;
    if (kind === "entries") add(all.filter(row => normalizeAtRepoParam(row.publicationId) === normalizeAtRepoParam(String(scope))));
    if (kind !== "aggregateEntries") continue;
    if (scope === "following") add(projection.followingTabPublications);
    if (scope === "subscribed") {
      add(projection.myPublications);
      add(projection.subscribedUnfoldered);
      for (const folder of projection.folderSections ?? []) add(folder.publications);
    }
    if (scope === "folder") for (const folder of projection.folderSections ?? []) {
      if (folder.folderRkey === id || folder.folderUri === id) add(folder.publications);
    }
  }
  return [...selected.values()];
}

/** Await ingestion in small batches and paint completed batches even if another source fails. */
export async function refreshPublicationSources(args: {
  oauthSession: OAuthSession;
  rows: SidebarPublicationRow[];
  signal: AbortSignal;
  onProgress: (completed: number, total: number) => void;
  onBatch: () => Promise<void>;
}): Promise<void> {
  const sources = new Map<string, { author?: string; feed?: string }>();
  for (const row of args.rows) {
    const scope = row.appViewScope;
    if (scope.authorDid === "did:web:skyreader.rss") {
      for (const feed of scope.publicationSiteUrls) sources.set(feed, { feed });
    } else if (scope.authorDid) sources.set(scope.authorDid, { author: scope.authorDid });
  }
  const pending = [...sources.values()];
  let failed = 0;
  args.onProgress(0, pending.length);
  for (let start = 0; start < pending.length; start += 4) {
    args.signal.throwIfAborted();
    const batch = pending.slice(start, start + 4);
    try {
      const signal = AbortSignal.any([args.signal, AbortSignal.timeout(30_000)]);
      await awaitWithAbort(enrollAuthorsInAppView(
        args.oauthSession,
        batch.flatMap(source => source.author ? [source.author] : []),
        batch.flatMap(source => source.feed ? [source.feed] : []),
        signal,
      ), signal);
    } catch {
      args.signal.throwIfAborted();
      failed += batch.length;
    }
    args.signal.throwIfAborted();
    await args.onBatch();
    args.onProgress(Math.min(start + batch.length, pending.length), pending.length);
  }
  if (failed) throw new Error("Some publications could not be checked. Articles received so far are available. Try Refresh again.");
}
