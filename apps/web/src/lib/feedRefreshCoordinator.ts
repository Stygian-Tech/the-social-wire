import type { QueryClient } from "@tanstack/react-query";

const publicSession = {};
const pendingByClient = new WeakMap<QueryClient, WeakMap<object, Map<string, Promise<unknown>>>>();
const readRevisions = new WeakMap<QueryClient, WeakMap<object, number>>();

export function readFeedRefreshRevision(client: QueryClient, session: object): number {
  return readRevisions.get(client)?.get(session) ?? 0;
}

/** Read mutations retire page-one work that started with older read flags. */
export function invalidateReadFeedRefreshes(client: QueryClient, session: object): void {
  let revisions = readRevisions.get(client);
  if (!revisions) { revisions = new WeakMap(); readRevisions.set(client, revisions); }
  revisions.set(session, readFeedRefreshRevision(client, session) + 1);
  const pending = pendingByClient.get(client)?.get(session);
  for (const key of pending?.keys() ?? []) {
    const domain = JSON.parse(key)[0];
    if (domain === "entries" || domain === "aggregateEntries") pending?.delete(key);
  }
}

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
  const key = JSON.stringify(queryKey);
  const existing = pending.get(key);
  if (existing) return existing as Promise<T>;
  const task = fetchPage().finally(() => {
    if (pending.get(key) === task) pending.delete(key);
  });
  pending.set(key, task);
  return task;
}
