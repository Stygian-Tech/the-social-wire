import { hashKey, type QueryClient } from "@tanstack/react-query";
import { awaitWithAbort } from "@/lib/awaitWithAbort";

const revisionsByClient = new WeakMap<QueryClient, Map<string, number>>();
const viewerReadStateRevisionsByClient = new WeakMap<QueryClient, Map<string, number>>();

/** Read changes retire stream snapshots even before a feed query exists. */
export function getViewerReadStateRevision(client: QueryClient, viewerDid: string): number {
  return viewerReadStateRevisionsByClient.get(client)?.get(viewerDid) ?? 0;
}

/** Current write generation for one complete feed query scope. */
export function getFeedRefreshRevision(client: QueryClient, queryKey: readonly unknown[]): number {
  return revisionsByClient.get(client)?.get(hashKey(queryKey)) ?? 0;
}

/** Freeze existing generations before a stream reveals its eventual feed scope. */
export function captureFeedRefreshRevisions(client: QueryClient): (queryKey: readonly unknown[]) => number {
  const revisions = new Map(revisionsByClient.get(client));
  return queryKey => revisions.get(hashKey(queryKey)) ?? 0;
}

/** Supersede pending direct cache writes before cancelling or fetching reader queries. */
export function advanceFeedRefreshRevision(client: QueryClient, queryKey: readonly unknown[]): number {
  let revisions = revisionsByClient.get(client);
  if (!revisions) { revisions = new Map(); revisionsByClient.set(client, revisions); }
  const key = hashKey(queryKey);
  const revision = (revisions.get(key) ?? 0) + 1;
  revisions.set(key, revision);
  return revision;
}

/** Retire viewer feed reads before changing read state, preserving optimistic data. */
export function cancelViewerFeedRefreshes(client: QueryClient, viewerDid: string): Promise<void> {
  let readRevisions = viewerReadStateRevisionsByClient.get(client);
  if (!readRevisions) { readRevisions = new Map(); viewerReadStateRevisionsByClient.set(client, readRevisions); }
  readRevisions.set(viewerDid, getViewerReadStateRevision(client, viewerDid) + 1);
  const filters = {
    predicate: (query: { queryKey: readonly unknown[] }) => query.queryKey[1] === viewerDid &&
      (query.queryKey[0] === "entries" || query.queryKey[0] === "aggregateEntries"),
  };
  const queries = client.getQueryCache().findAll(filters);
  for (const query of queries) advanceFeedRefreshRevision(client, query.queryKey);
  // Silent cancellation must settle fetchStatus explicitly. Reverting would undo
  // newer optimistic data; reporting cancellation as an error would flash Retry.
  const cancelled = client.cancelQueries(filters, { revert: false, silent: true });
  for (const query of queries) query.setState({ fetchStatus: "idle" });
  return cancelled.then(() => {
    // A read action can happen in another pane during an initial feed load.
    // Cached feeds keep their data; cold active feeds need a replacement request.
    void client.refetchQueries({
      predicate: query => filters.predicate(query) && query.isActive() &&
        query.state.data === undefined && query.state.fetchStatus === "idle",
    });
  });
}

const publicSession = {};
type PendingFirstPage = { promise: Promise<unknown>; signal?: AbortSignal };
const pendingByClient = new WeakMap<QueryClient, WeakMap<object, Map<string, PendingFirstPage>>>();

/** Share only page-one work for the same OAuth session and complete feed scope. */
export function coalesceFeedFirstPage<T>(
  client: QueryClient,
  session: object | null,
  queryKey: readonly unknown[],
  fetchPage: () => Promise<T>,
  signal?: AbortSignal,
): Promise<T> {
  if (signal?.aborted) return Promise.reject(signal.reason);
  let sessions = pendingByClient.get(client);
  if (!sessions) { sessions = new WeakMap(); pendingByClient.set(client, sessions); }
  const owner = session ?? publicSession;
  let pending = sessions.get(owner);
  if (!pending) { pending = new Map(); sessions.set(owner, pending); }
  const key = hashKey([queryKey, getFeedRefreshRevision(client, queryKey)]);
  const existing = pending.get(key);
  if (existing && !existing.signal?.aborted) return existing.promise as Promise<T>;
  const retire = () => {
    // Abort precedes transport settlement. Late cleanup must preserve a replacement.
    if (pending.get(key) === entry) pending.delete(key);
  };
  const work = fetchPage();
  // Every joined consumer must observe cancellation, including direct cache writers.
  const task = (signal ? awaitWithAbort(work, signal) : work).finally(() => {
    signal?.removeEventListener("abort", retire);
    retire();
  });
  const entry = { promise: task, signal };
  pending.set(key, entry);
  signal?.addEventListener("abort", retire, { once: true });
  if (signal?.aborted) retire();
  return task;
}
