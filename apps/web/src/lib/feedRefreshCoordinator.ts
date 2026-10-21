import { hashKey, type QueryClient } from "@tanstack/react-query";

const revisionsByClient = new WeakMap<QueryClient, Map<string, number>>();

/** Current write generation for one complete feed query scope. */
export function getFeedRefreshRevision(client: QueryClient, queryKey: readonly unknown[]): number {
  return revisionsByClient.get(client)?.get(hashKey(queryKey)) ?? 0;
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
  return cancelled;
}

const publicSession = {};
const pendingByClient = new WeakMap<QueryClient, WeakMap<object, Map<string, Promise<unknown>>>>();

/** Share only page-one work for the same OAuth session and complete feed scope. */
export function coalesceFeedFirstPage<T>(
  client: QueryClient,
  session: object | null,
  queryKey: readonly unknown[],
  fetchPage: () => Promise<T>,
): Promise<T> {
  let sessions = pendingByClient.get(client);
  if (!sessions) { sessions = new WeakMap(); pendingByClient.set(client, sessions); }
  const owner = session ?? publicSession;
  let pending = sessions.get(owner);
  if (!pending) { pending = new Map(); sessions.set(owner, pending); }
  const key = hashKey([queryKey, getFeedRefreshRevision(client, queryKey)]);
  const existing = pending.get(key);
  if (existing) return existing as Promise<T>;
  const task = fetchPage().finally(() => {
    if (pending.get(key) === task) pending.delete(key);
  });
  pending.set(key, task);
  return task;
}
