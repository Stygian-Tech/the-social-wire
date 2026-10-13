import type { QueryClient } from "@tanstack/react-query";

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
  const key = JSON.stringify(queryKey);
  const existing = pending.get(key);
  if (existing) return existing as Promise<T>;
  const task = fetchPage().finally(() => {
    if (pending.get(key) === task) pending.delete(key);
  });
  pending.set(key, task);
  return task;
}
