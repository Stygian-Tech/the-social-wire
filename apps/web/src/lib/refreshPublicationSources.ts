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

/** Compare source work independently of row order and duplicate scope aliases. */
export function readerRefreshSourcesKey(rows: SidebarPublicationRow[]): { membership: string[]; sources: string[]; scopes: string[] } {
  const normalizeSite = (site: string) => {
    try { return new URL(site).href; } catch { return site; }
  };
  const normalizedSet = (values: string[]) => [...new Set(values)].sort();
  const sources = new Set<string>();
  for (const { appViewScope: scope } of rows) {
    if (scope.authorDid === "did:web:skyreader.rss") {
      for (const feed of scope.publicationSiteUrls) {
        if (!feed.trim()) continue;
        sources.add(`feed:${normalizeSite(feed)}`);
      }
    } else if (scope.authorDid) sources.add(`author:${normalizeAtRepoParam(scope.authorDid)}`);
  }
  return {
    membership: [...new Set(rows.map(row => normalizeAtRepoParam(row.publicationId)))].sort(),
    sources: [...sources].sort(),
    // Enrollment can stay author-scoped while the server changes which of that
    // author's publications/URLs belong to a row. Such changes need seed cleanup.
    scopes: normalizedSet(rows.map(row => JSON.stringify([
      normalizeAtRepoParam(row.publicationId),
      normalizeAtRepoParam(row.appViewScope.authorDid ?? ""),
      row.appViewScope.publicationAtUri ? normalizeAtRepoParam(row.appViewScope.publicationAtUri) : null,
      normalizedSet(row.appViewScope.publicationScopeAtUris.map(normalizeAtRepoParam)),
      normalizedSet(row.appViewScope.publicationSiteUrls.map(normalizeSite)),
    ]))),
  };
}

/** Poll mounted feeds while scoped enrollment requests ingest and recount. */
export async function refreshPublicationSources(args: {
  oauthSession: OAuthSession;
  rows: SidebarPublicationRow[];
  signal: AbortSignal;
  onProgress: (completed: number, total: number) => void;
  onBatch: () => Promise<void>;
}): Promise<void> {
  args.signal.throwIfAborted();
  const authors = new Set<string>();
  const feeds = new Set<string>();
  for (const row of args.rows) {
    const scope = row.appViewScope;
    if (scope.authorDid === "did:web:skyreader.rss") {
      for (const feed of scope.publicationSiteUrls) feeds.add(feed);
    } else if (scope.authorDid) authors.add(scope.authorDid);
  }
  // The enroller caps authors at 500 and the lexicon caps each array at 1000;
  // use at most 500 combined sources and the route's 1 MiB JSON body limit.
  const requests: { authorDids: string[]; feedUrls: string[] }[] = [];
  let request = { authorDids: [] as string[], feedUrls: [] as string[] };
  const bytes = (value: typeof request) => new TextEncoder().encode(JSON.stringify(value)).length;
  for (const [kind, sources] of [["authorDids", authors], ["feedUrls", feeds]] as const) {
    for (const source of sources) {
      const next = { ...request, [kind]: [...request[kind], source] };
      if (request.authorDids.length + request.feedUrls.length >= 500 || bytes(next) > 1 << 20) {
        if (request.authorDids.length + request.feedUrls.length) requests.push(request);
        request = { authorDids: [], feedUrls: [] };
      }
      request[kind].push(source);
      if (bytes(request) > 1 << 20) throw new Error("A publication source exceeds the refresh request size limit.");
    }
  }
  if (request.authorDids.length + request.feedUrls.length) requests.push(request);
  const total = authors.size + feeds.size;
  args.onProgress(0, total);
  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let paint: Promise<void> | undefined;
  let paintFailure: unknown;
  const schedulePaint = () => {
    if (stopped || args.signal.aborted || paintFailure) return;
    timer = setTimeout(() => {
      if (stopped || args.signal.aborted) return;
      // Schedule only after this paint settles: slow reads never accumulate work
      // or hold up ingestion, and direct feed cache writes cannot race each other.
      paint = Promise.resolve().then(() => {
        args.signal.throwIfAborted();
        return args.onBatch();
      }).catch(error => {
        paintFailure = error;
      }).finally(schedulePaint);
    }, 1000);
  };
  let sourceFailure: unknown;
  if (total) {
    schedulePaint();
    try {
      for (const request of requests) {
        args.signal.throwIfAborted();
        try {
          // Preserve the former 30-second allowance per four sources without
          // letting one large request wait indefinitely. Caller abort stays independent.
          const sourceCount = request.authorDids.length + request.feedUrls.length;
          const deadlineMs = Math.min(300_000, 30_000 * Math.ceil(sourceCount / 4));
          const signal = AbortSignal.any([args.signal, AbortSignal.timeout(deadlineMs)]);
          await awaitWithAbort(enrollAuthorsInAppView(args.oauthSession, request.authorDids, request.feedUrls, signal), signal);
        } catch (error) {
          args.signal.throwIfAborted();
          sourceFailure ??= error;
        }
      }
    } finally {
      stopped = true;
      clearTimeout(timer);
      // Even a failed/cancelled request must settle its started feed workers.
      await paint;
    }
  }
  args.signal.throwIfAborted();
  // Completion may commit articles after the last poll started. Flush this dirty
  // interval once, including partial ingestion on failure; the caller must not
  // issue an additional unconditional feed refresh.
  if (!sourceFailure) args.onProgress(total, total);
  await args.onBatch();
  args.signal.throwIfAborted();
  if (sourceFailure) throw new Error("Some publications could not be checked. Articles received so far are available. Try Refresh again.", { cause: sourceFailure });
  if (paintFailure) throw paintFailure;
}
