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
