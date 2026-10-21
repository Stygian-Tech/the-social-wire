import { afterAll, afterEach, describe, expect, it, spyOn } from "bun:test";
import { InfiniteQueryObserver, QueryClient, type InfiniteData, type QueryKey } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";

import type { EntriesPage } from "@/hooks/useEntries";
import * as appView from "@/lib/thinAppViewClient";
import { advanceFeedRefreshRevision, recordReadEntryMutations } from "@/lib/feedRefreshCoordinator";
import { refreshReaderFeeds } from "@/lib/refreshReaderFeeds";

const viewerDid = "did:plc:viewer";
const oauthSession = { did: viewerDid } as unknown as OAuthSession;
const entry = (entryId: string) => ({ entryId, title: entryId, publishedAt: "2026-10-20T00:00:00Z" });
const page = (...ids: string[]): EntriesPage => ({ entries: ids.map(entry) });
const publication = (id: string, filter = "all", did = viewerDid) => ["entries", did, id, filter] as const;
const aggregate = (kind = "subscribed", id = "", filter = "all") => ["aggregateEntries", viewerDid, kind, id, filter] as const;
const deferred = <T,>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
};

describe("refreshReaderFeeds", () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const unsubscribes: (() => void)[] = [];
  const fetchPage = spyOn(appView, "listAggregateFeedFromAppView");
  afterAll(() => fetchPage.mockRestore());
  const seed = (queryKey: QueryKey, pages = [page("old")]) => {
    const data: InfiniteData<EntriesPage> = { pages, pageParams: pages.map((_, index) => index ? `page-${index + 1}` : undefined) };
    client.setQueryData(queryKey, data);
    return data;
  };
  const activate = (queryKey: QueryKey) => {
    const queryFn = () => Promise.reject(new Error("must not refetch paginated query"));
    const observer = new InfiniteQueryObserver<EntriesPage>(client, {
      queryKey, queryFn, initialPageParam: undefined as string | undefined,
      getNextPageParam: (last: EntriesPage) => last.cursor, staleTime: Infinity,
    });
    unsubscribes.push(observer.subscribe(() => {}));
    return observer;
  };
  const refresh = (signal?: AbortSignal) => refreshReaderFeeds({ queryClient: client, viewerDid, oauthSession, signal });

  afterEach(() => {
    unsubscribes.splice(0).forEach(unsubscribe => unsubscribe());
    client.clear();
    fetchPage.mockReset();
  });

  it("refreshes only active viewer feeds, leaves inactive feeds stale, and preserves All tail pages", async () => {
    const active = publication("pub");
    const inactive = publication("inactive");
    const otherViewer = publication("pub", "all", "did:plc:other");
    const unrelated = ["entry", "article"];
    const original = seed(active, [{ ...page("old"), cursor: "page-2" }, page("tail")]);
    seed(inactive);
    seed(otherViewer);
    client.setQueryData(unrelated, { title: "article detail" });
    activate(active);
    activate(otherViewer);
    fetchPage.mockResolvedValue({ ...page("new", "old"), cursor: "fresh-cursor" });

    expect(await refresh()).toEqual({ newArticleCount: 1 });
    expect(fetchPage).toHaveBeenCalledTimes(1);
    expect(fetchPage).toHaveBeenCalledWith({ feed: { kind: "publication", id: "pub" }, filter: "all", oauthSession, signal: expect.any(AbortSignal) });
    const updated = client.getQueryData<InfiniteData<EntriesPage>>(active)!;
    expect(updated.pages[0].entries.map(item => item.entryId)).toEqual(["new", "old"]);
    expect(updated.pages[1]).toEqual(original.pages[1]);
    expect(updated.pageParams).toEqual(original.pageParams);
    expect(client.getQueryState(active)?.isInvalidated).toBe(false);
    expect(client.getQueryState(inactive)?.isInvalidated).toBe(true);
    expect(client.getQueryState(otherViewer)?.isInvalidated).toBe(false);
    expect(client.getQueryState(unrelated)?.isInvalidated).toBe(false);
  });

  it("replaces unread history and deduplicates new articles across overlapping active feeds", async () => {
    const all = aggregate();
    const unread = aggregate("subscribed", "", "unread");
    const folder = aggregate("folder", "folder-id");
    seed(all, [page("known", "already-in-all"), page("tail")]);
    seed(unread, [page("now-read"), page("stale-unread-tail")]);
    seed(folder);
    [all, unread, folder].forEach(activate);
    fetchPage.mockResolvedValue(page("new", "already-in-all"));

    expect(await refresh()).toEqual({ newArticleCount: 1 });
    expect(fetchPage).toHaveBeenCalledTimes(3);
    expect(client.getQueryData<InfiniteData<EntriesPage>>(unread)).toEqual({ pages: [page("new", "already-in-all")], pageParams: [undefined] });
    expect(client.getQueryData<InfiniteData<EntriesPage>>(all)?.pages[1]).toEqual(page("tail"));
    expect(fetchPage.mock.calls.some(([args]) => args.feed.kind === "folder" && args.feed.id === "folder-id")).toBe(true);
    expect(fetchPage.mock.calls.every(([args]) => args.cursor === undefined)).toBe(true);
  });

  it("reports only actual fresh IDs when navigation activates cached articles during a paint", async () => {
    const original = publication("original");
    const navigated = publication("navigated");
    seed(original, [page("original-cached")]);
    seed(navigated, [page("navigated-cached")]);
    activate(original);
    const started = deferred<void>(), response = deferred<EntriesPage>();
    fetchPage.mockImplementation(async () => { started.resolve(); return response.promise; });
    const reported: string[][] = [];
    const task = refreshReaderFeeds({ queryClient: client, viewerDid, oauthSession, onNewArticleIds: ids => reported.push([...ids]) });
    await started.promise;
    // Navigation paints pre-existing rows. They are not results of this read.
    activate(navigated);
    response.resolve(page("new", "original-cached"));
    expect(await task).toEqual({ newArticleCount: 1 });
    expect(reported).toEqual([["new"]]);
    expect(fetchPage).toHaveBeenCalledTimes(1);
    fetchPage.mockImplementation(async ({ feed }) => feed.id === "navigated" ? page("navigated-cached") : page("new", "original-cached"));
    await refreshReaderFeeds({ queryClient: client, viewerDid, oauthSession, onNewArticleIds: ids => reported.push([...ids]) });
    expect(reported).toEqual([["new"], []]);
  });

  it("marks inactive feeds stale without issuing reads and allows their next mount to refetch", async () => {
    const key = publication("inactive");
    seed(key);
    expect(await refresh()).toEqual({ newArticleCount: 0 });
    expect(fetchPage).not.toHaveBeenCalled();
    const fetched = deferred<void>();
    const observer = new InfiniteQueryObserver(client, {
      queryKey: key, initialPageParam: undefined,
      getNextPageParam: () => undefined, refetchOnMount: true,
      queryFn: async () => page("mounted"),
    });
    unsubscribes.push(observer.subscribe(result => {
      if (result.isSuccess && !result.isFetching) fetched.resolve();
    }));
    await fetched.promise;
    expect(client.getQueryData<InfiniteData<EntriesPage>>(key)?.pages).toEqual([page("mounted")]);
  });

  it("preserves cached data and invalidation while propagating a refresh failure", async () => {
    const key = aggregate("list", "list-id");
    const original = seed(key, [page("old"), page("tail")]);
    activate(key);
    fetchPage.mockRejectedValue(new Error("offline"));
    await expect(refresh()).rejects.toThrow("offline");
    expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(original);
    expect(client.getQueryState(key)?.isInvalidated).toBe(true);
  });

  it("does not write responses after abort, even when the transport ignores the signal", async () => {
    const key = publication("pub");
    const original = seed(key);
    activate(key);
    const controller = new AbortController();
    const started = deferred<void>();
    const response = deferred<EntriesPage>();
    fetchPage.mockImplementation(async () => { started.resolve(); return response.promise; });
    const pending = refresh(controller.signal);
    await started.promise;
    controller.abort();
    response.resolve(page("new"));
    await expect(pending).rejects.toHaveProperty("name", "AbortError");
    expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(original);
    expect(client.getQueryState(key)?.isInvalidated).toBe(true);
    expect(fetchPage.mock.calls[0][0].signal?.aborted).toBe(true);
  });

  for (const isRead of [true, false]) {
    it(`preserves an explicit ${isRead ? "read" : "unread"} gesture during a manual feed request`, async () => {
      const key = aggregate();
      const original = { ...entry("old"), isRead: !isRead };
      seed(key, [{ entries: [original] }]);
      activate(key);
      const started = deferred<void>(), response = deferred<EntriesPage>();
      fetchPage.mockImplementation(async () => { started.resolve(); return response.promise; });
      const task = refresh();
      await started.promise;
      recordReadEntryMutations(client, oauthSession, ["old"]);
      const chosen = seed(key, [{ entries: [{ ...original, isRead }] }]);
      response.resolve({ entries: [original, entry("stale-new")] });
      expect(await task).toEqual({ newArticleCount: 0 });
      expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(chosen);
    });
  }

  it("rejects an old account response even if transport and caller signal remain live", async () => {
    const key = publication("pub");
    const original = seed(key);
    activate(key);
    let current = true;
    const started = deferred<void>(), response = deferred<EntriesPage>();
    fetchPage.mockImplementation(async () => { started.resolve(); return response.promise; });
    const task = refreshReaderFeeds({ queryClient: client, viewerDid, oauthSession, isCurrentSession: () => current });
    await started.promise;
    current = false;
    response.resolve(page("wrong-account"));
    await expect(task).rejects.toHaveProperty("name", "AbortError");
    expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(original);
  });

  it("cannot overwrite a newer per-query generation", async () => {
    const key = publication("pub");
    seed(key); activate(key);
    const started = deferred<void>(), response = deferred<EntriesPage>();
    fetchPage.mockImplementation(async () => { started.resolve(); return response.promise; });
    const task = refresh();
    await started.promise;
    advanceFeedRefreshRevision(client, key);
    const newer = seed(key, [page("newer")]);
    response.resolve(page("obsolete"));
    expect(await task).toEqual({ newArticleCount: 0 });
    expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(newer);
  });

  it("settles on a deadline even when a stalled transport ignores cancellation", async () => {
    const key = publication("pub");
    const original = seed(key);
    activate(key);
    const deadline = new AbortController();
    const timeout = spyOn(AbortSignal, "timeout").mockReturnValue(deadline.signal);
    const started = deferred<void>();
    fetchPage.mockImplementation(async () => { started.resolve(); return new Promise<EntriesPage>(() => {}); });
    try {
      const pending = refresh();
      await started.promise;
      deadline.abort(new DOMException("Timed out", "TimeoutError"));
      await expect(pending).rejects.toHaveProperty("name", "TimeoutError");
      expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(original);
    } finally { timeout.mockRestore(); }
  });

  it("does no work for an already-aborted signal", async () => {
    const key = publication("pub");
    seed(key);
    const controller = new AbortController();
    controller.abort();
    await expect(refresh(controller.signal)).rejects.toHaveProperty("name", "AbortError");
    expect(fetchPage).not.toHaveBeenCalled();
    expect(client.getQueryState(key)?.isInvalidated).toBe(false);
  });

  it("awaits cancellation before reading baseline data or starting fresh requests", async () => {
    const key = publication("pub");
    seed(key);
    const observer = activate(key);
    const staleResponse = deferred<EntriesPage>();
    const events: string[] = [];
    observer.setOptions({
      queryKey: key,
      staleTime: Infinity,
      initialPageParam: undefined,
      getNextPageParam: (last: EntriesPage) => last.cursor,
      queryFn: async ({ signal }) => {
      signal.addEventListener("abort", () => { events.push("cancelled"); }, { once: true });
      return staleResponse.promise;
    } });
    const stale = observer.refetch();
    const cancelQueries = client.cancelQueries.bind(client);
    const cancel = spyOn(client, "cancelQueries");
    const cancelled = deferred<void>();
    const release = deferred<void>();
    cancel.mockImplementation(async (...args) => {
      await cancelQueries(...args);
      cancelled.resolve();
      await release.promise;
      // This is the authoritative baseline only available after cancellation settles.
      seed(key, [page("baseline")]);
    });
    fetchPage.mockImplementation(async () => { events.push("read"); return page("baseline", "new"); });
    try {
      const pending = refresh();
      await cancelled.promise;
      expect(fetchPage).not.toHaveBeenCalled();
      release.resolve();
      expect(await pending).toEqual({ newArticleCount: 1 });
      staleResponse.resolve(page("stale"));
      await stale;
      expect(events).toEqual(["cancelled", "read"]);
      expect(client.getQueryData<InfiniteData<EntriesPage>>(key)?.pages[0].entries.map(item => item.entryId)).toEqual(["baseline", "new"]);
    } finally {
      cancel.mockRestore();
    }
  });

  it("settles sibling workers before rejecting and stops dispatching after one fails", async () => {
    for (let index = 0; index < 4; index++) { const key = publication(`pub-${index}`); seed(key); activate(key); }
    const started = deferred<void>(), fail = deferred<void>(), release = deferred<void>();
    let running = 0;
    fetchPage.mockImplementation(async ({ feed }) => {
      if (++running === 3) started.resolve();
      if (feed.id === "pub-0") { await fail.promise; throw new Error("feed failed"); }
      await release.promise;
      return page("partial");
    });
    let settled = false, reported = false;
    const outcome = refreshReaderFeeds({ queryClient: client, viewerDid, oauthSession, onNewArticleIds: () => { reported = true; } }).catch(error => { settled = true; return error; });
    await started.promise;
    fail.resolve();
    for (let index = 0; index < 12; index++) await Promise.resolve();
    expect(settled).toBe(false);
    expect(fetchPage).toHaveBeenCalledTimes(3);
    release.resolve();
    expect((await outcome).message).toBe("feed failed");
    expect(reported).toBe(false);
    expect(fetchPage).toHaveBeenCalledTimes(3);
    const snapshot = client.getQueryData<InfiniteData<EntriesPage>>(publication("pub-1"));
    await Promise.resolve();
    expect(client.getQueryData<InfiniteData<EntriesPage>>(publication("pub-1"))).toBe(snapshot);
  });

  it("bounds active first-page refreshes to three concurrent requests", async () => {
    for (let index = 0; index < 7; index++) {
      const key = publication(`pub-${index}`);
      seed(key);
      activate(key);
    }
    const firstBatch = deferred<void>();
    const release = deferred<void>();
    let running = 0;
    let maximum = 0;
    fetchPage.mockImplementation(async () => {
      running++;
      maximum = Math.max(maximum, running);
      if (running === 3) firstBatch.resolve();
      await release.promise;
      running--;
      return page("new");
    });
    const pending = refresh();
    await firstBatch.promise;
    expect(fetchPage).toHaveBeenCalledTimes(3);
    release.resolve();
    expect(await pending).toEqual({ newArticleCount: 1 });
    expect(fetchPage).toHaveBeenCalledTimes(7);
    expect(maximum).toBe(3);
  });
});
