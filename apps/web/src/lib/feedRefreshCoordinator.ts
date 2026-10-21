import { hashKey, type QueryClient } from "@tanstack/react-query";
import { awaitWithAbort } from "@/lib/awaitWithAbort";

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
type PendingFirstPage = { promise: Promise<unknown>; signal?: AbortSignal };
const pendingByClient = new WeakMap<QueryClient, WeakMap<object, Map<string, PendingFirstPage>>>();
const entryMutations = new WeakMap<QueryClient, WeakMap<object, Map<string, number>>>();
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
    const domain = JSON.parse(key)[0][0];
    if (domain === "entries" || domain === "aggregateEntries") pending?.delete(key);
  }
}

/** Explicit gestures own entries independently of unrelated refresh/reconciliation work. */
export function recordReadEntryMutations(client: QueryClient, session: object, entryIds: readonly string[]): number {
  invalidateReadFeedRefreshes(client, session);
  let sessions = entryMutations.get(client);
  if (!sessions) { sessions = new WeakMap(); entryMutations.set(client, sessions); }
  let entries = sessions.get(session);
  if (!entries) { entries = new Map(); sessions.set(session, entries); }
  const revision = readFeedRefreshRevision(client, session);
  for (const entryId of entryIds) entries.set(entryId, revision);
  return revision;
}

export function readEntryMutationRevision(client: QueryClient, session: object, entryId: string): number {
  return entryMutations.get(client)?.get(session)?.get(entryId) ?? 0;
}

const pendingBulkReads = new WeakMap<QueryClient, WeakMap<object, object>>();
const bulkReadListeners = new WeakMap<QueryClient, Set<() => void>>();

export function subscribeBulkReadPending(client: QueryClient, listener: () => void): () => void {
  let listeners = bulkReadListeners.get(client);
  if (!listeners) { listeners = new Set(); bulkReadListeners.set(client, listeners); }
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

export function bulkReadPending(client: QueryClient, session: object | null): boolean {
  return Boolean(session && pendingBulkReads.get(client)?.has(session));
}

/** Acquire before optimism so sidebar and toolbar actions cannot share an unconfirmed baseline. */
export function acquireBulkRead(client: QueryClient, session: object): object | null {
  let sessions = pendingBulkReads.get(client);
  if (!sessions) { sessions = new WeakMap(); pendingBulkReads.set(client, sessions); }
  if (sessions.has(session)) return null;
  const owner = {};
  sessions.set(session, owner);
  bulkReadListeners.get(client)?.forEach(listener => listener());
  return owner;
}

export function releaseBulkRead(client: QueryClient, session: object, owner: object): void {
  const sessions = pendingBulkReads.get(client);
  if (sessions?.get(session) !== owner) return;
  sessions.delete(session);
  bulkReadListeners.get(client)?.forEach(listener => listener());
}

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
