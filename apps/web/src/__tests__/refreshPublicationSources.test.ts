import { afterEach, expect, it, spyOn } from "bun:test";
import { InfiniteQueryObserver, QueryClient } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as appview from "@/lib/thinAppViewClient";
import { readerRefreshRows, refreshPublicationSources } from "@/lib/refreshPublicationSources";
import type { PublicationSidebarProjection, SidebarPublicationRow } from "@/lib/publicationProjectionClient";

const oauthSession = {} as OAuthSession;
const row = (author: string, id = author): SidebarPublicationRow => ({ publicationId: id, authorDid: author, authorHandle: author, title: author, discoveredAt: "", appViewScope: { authorDid: author, publicationAtUri: null, publicationScopeAtUris: [], publicationSiteUrls: [] } });
const restores: (() => void)[] = [];
afterEach(() => { while (restores.length) restores.pop()!(); });

function deferred() {
  let resolve!: () => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<void>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}
const settle = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function paintClock() {
  const timers: { callback: () => void; cleared: boolean }[] = [];
  const originalSet = globalThis.setTimeout;
  const originalClear = globalThis.clearTimeout;
  const set = spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void, delay: number, ...rest: unknown[]) => {
    if (delay !== 1000) return originalSet(callback, delay, ...rest);
    const timer = { callback, cleared: false };
    timers.push(timer);
    return timer as unknown as ReturnType<typeof setTimeout>;
  }) as typeof setTimeout);
  const clear = spyOn(globalThis, "clearTimeout").mockImplementation(((timer: ReturnType<typeof setTimeout>) => {
    const found = timers.find(value => value === timer as unknown);
    if (found) found.cleared = true;
    else originalClear(timer);
  }) as typeof clearTimeout);
  restores.push(() => set.mockRestore(), () => clear.mockRestore());
  return { timers, tick: async () => {
    const timer = timers.find(value => !value.cleared);
    if (!timer) throw new Error("No paint scheduled");
    timer.cleared = true;
    timer.callback();
    await settle();
  } };
}
function refresh(onBatch: () => Promise<void>, signal = new AbortController().signal, rows = [row("did:plc:one")], onProgress: (completed: number, total: number) => void = () => {}) {
  return refreshPublicationSources({ oauthSession, rows, signal, onBatch, onProgress });
}

it("sends 77 deduplicated sources in one RPC and flushes once after the counter barrier", async () => {
  const events: string[] = [];
  const gate = deferred();
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(async () => { events.push("enroll"); await gate.promise; });
  restores.push(() => enroll.mockRestore());
  const clock = paintClock();
  const rss = row("did:web:skyreader.rss", "rss");
  rss.appViewScope.publicationSiteUrls = ["https://feed.test/rss", "https://feed.test/rss"];
  const task = refresh(async () => { events.push("paint"); }, undefined, [...Array.from({ length: 76 }, (_, i) => row(`did:plc:${i}`)), row("did:plc:0"), rss], (n, total) => events.push(`${n}/${total}`));
  expect(enroll).toHaveBeenCalledTimes(1);
  expect(enroll.mock.calls[0]?.[1]).toHaveLength(76);
  expect(enroll.mock.calls[0]?.[2]).toEqual(["https://feed.test/rss"]);
  expect(events).toEqual(["0/77", "enroll"]);
  gate.resolve(); await task;
  expect(events).toEqual(["0/77", "enroll", "77/77", "paint"]);
  expect(clock.timers.every(timer => timer.cleared)).toBe(true);
});

it("paints early without claiming checked sources while ingestion remains pending", async () => {
  const gate = deferred();
  const progress: number[] = [];
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(() => gate.promise);
  restores.push(() => enroll.mockRestore());
  const clock = paintClock();
  let paints = 0;
  let finished = false;
  const task = refresh(async () => { paints++; }, undefined, undefined, n => progress.push(n)).then(() => { finished = true; });
  await clock.tick();
  expect(paints).toBe(1);
  expect(progress).toEqual([0]);
  expect(finished).toBe(false);
  await clock.tick();
  expect(paints).toBe(2);
  gate.resolve(); await task;
  expect(paints).toBe(3);
  expect(progress).toEqual([0, 1]);
});

it("bounds paints to one worker and ingestion finishes without waiting for a slow paint", async () => {
  const gate = deferred(), slowPaint = deferred();
  let ingested = false;
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(async () => { await gate.promise; ingested = true; });
  restores.push(() => enroll.mockRestore());
  const clock = paintClock();
  let paints = 0, finished = false;
  const task = refresh(async () => { if (++paints === 1) await slowPaint.promise; }).then(() => { finished = true; });
  await clock.tick();
  expect(paints).toBe(1);
  expect(clock.timers.filter(timer => !timer.cleared)).toHaveLength(0);
  gate.resolve(); await settle();
  expect(ingested).toBe(true);
  expect(finished).toBe(false);
  expect(paints).toBe(1);
  slowPaint.resolve(); await task;
  expect(paints).toBe(2);
  expect(clock.timers.filter(timer => !timer.cleared)).toHaveLength(0);
});

it("flushes partial articles before surfacing enrollment failure without completed progress", async () => {
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockRejectedValue(new Error("upstream"));
  restores.push(() => enroll.mockRestore());
  const clock = paintClock();
  const progress: number[] = [];
  let paints = 0;
  await expect(refresh(async () => { paints++; }, undefined, undefined, n => progress.push(n))).rejects.toThrow("Some publications");
  expect(paints).toBe(1);
  expect(progress).toEqual([0]);
  expect(clock.timers.every(timer => timer.cleared)).toBe(true);
});

it("settles a started paint on cancellation and never flushes or polls afterward", async () => {
  const controller = new AbortController();
  const gate = deferred(), slowPaint = deferred();
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(() => gate.promise);
  restores.push(() => enroll.mockRestore());
  const clock = paintClock();
  let paints = 0, settled = false;
  const outcome = refresh(async () => { paints++; await slowPaint.promise; }, controller.signal).catch(error => { settled = true; return error; });
  await clock.tick();
  controller.abort(); await settle();
  expect(settled).toBe(false);
  slowPaint.resolve();
  expect(await outcome).toBeInstanceOf(DOMException);
  gate.resolve();
  for (const timer of clock.timers) timer.callback();
  await settle();
  expect(paints).toBe(1);
  expect(clock.timers.filter(timer => !timer.cleared)).toHaveLength(0);
});

it("waits for a failed periodic paint, flushes once, and never reports success", async () => {
  const gate = deferred();
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(() => gate.promise);
  restores.push(() => enroll.mockRestore());
  const clock = paintClock();
  let paints = 0;
  const progress: number[] = [];
  const task = refresh(async () => { if (++paints === 1) throw new Error("feed unavailable"); }, undefined, undefined, n => progress.push(n));
  const outcome = task.catch(error => error);
  await clock.tick();
  expect(paints).toBe(1);
  expect(clock.timers.filter(timer => !timer.cleared)).toHaveLength(0);
  gate.resolve();
  expect((await outcome).message).toBe("feed unavailable");
  expect(paints).toBe(2);
  expect(progress).toEqual([0, 1]);
});

it("continues large scope chunks after an upstream failure and retains partial articles", async () => {
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(async () => { if (enroll.mock.calls.length === 1) throw new Error("first chunk"); });
  restores.push(() => enroll.mockRestore());
  paintClock();
  let paints = 0;
  await expect(refresh(async () => { paints++; }, undefined, Array.from({ length: 501 }, (_, i) => row(`did:plc:${i}`)))).rejects.toThrow("Some publications");
  expect(enroll).toHaveBeenCalledTimes(2);
  expect(paints).toBe(1);
});

it("does no work for an already aborted refresh", async () => {
  const controller = new AbortController(); controller.abort();
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockResolvedValue(undefined);
  restores.push(() => enroll.mockRestore());
  let paints = 0;
  await expect(refresh(async () => { paints++; }, controller.signal)).rejects.toThrow();
  expect(enroll).not.toHaveBeenCalled(); expect(paints).toBe(0);
});

it("refreshes feeds once without an enrollment request when no sources are selected", async () => {
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockResolvedValue(undefined);
  restores.push(() => enroll.mockRestore());
  let paints = 0;
  await refresh(async () => { paints++; }, undefined, []);
  expect(enroll).not.toHaveBeenCalled(); expect(paints).toBe(1);
});

it("partitions oversized scopes into serial server-sized requests without dropping sources", async () => {
  const first = deferred();
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(async () => { if (enroll.mock.calls.length === 1) await first.promise; });
  restores.push(() => enroll.mockRestore());
  paintClock();
  const rows = Array.from({ length: 501 }, (_, i) => row(`did:plc:${i}`));
  const rss = row("did:web:skyreader.rss", "rss");
  rss.appViewScope.publicationSiteUrls = Array.from({ length: 501 }, (_, i) => `https://feed.test/${i}`);
  const task = refresh(async () => {}, undefined, [...rows, rss]);
  expect(enroll).toHaveBeenCalledTimes(1);
  first.resolve(); await task;
  expect(enroll.mock.calls.map(call => call[1].length + (call[2]?.length ?? 0))).toEqual([500, 500, 2]);
  expect(enroll.mock.calls.flatMap(call => call[1])).toEqual(rows.map(value => value.authorDid));
  expect(enroll.mock.calls.flatMap(call => call[2] ?? [])).toEqual(rss.appViewScope.publicationSiteUrls);
});

it("partitions by the JSON body limit and rejects a single oversized source", async () => {
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockResolvedValue(undefined);
  restores.push(() => enroll.mockRestore());
  paintClock();
  const rss = row("did:web:skyreader.rss", "rss");
  rss.appViewScope.publicationSiteUrls = ["https://feed.test/" + "a".repeat(600_000), "https://feed.test/" + "b".repeat(600_000)];
  await refresh(async () => {}, undefined, [rss]);
  expect(enroll).toHaveBeenCalledTimes(2);
  rss.appViewScope.publicationSiteUrls = ["https://feed.test/" + "a".repeat(1 << 20)];
  await expect(refresh(async () => {}, undefined, [rss])).rejects.toThrow("size limit");
  expect(enroll).toHaveBeenCalledTimes(2);
});

it("selects subscribed folders without enrolling the following graph or another viewer", () => {
  const client = new QueryClient();
  const subscribed = row("did:plc:subscribed"), folder = row("did:plc:folder"), following = row("did:plc:following");
  const projection: PublicationSidebarProjection = { viewerDid: "viewer", folders: [], publicationPrefs: [], allPublicationRows: [subscribed, folder, following], myPublications: [], subscribedUnfoldered: [subscribed], followingTabPublications: [following], folderSections: [{ folderRkey: "folder", folderUri: "at://folder", publications: [folder] }], enrollAuthorDids: [], refreshedAt: "" };
  const observer = new InfiniteQueryObserver(client, { queryKey: ["aggregateEntries", "viewer", "subscribed", "", "unread"], queryFn: async () => ({ entries: [] }), initialPageParam: undefined, getNextPageParam: () => undefined, staleTime: Infinity, initialData: { pages: [{ entries: [] }], pageParams: [undefined] } });
  const unsubscribe = observer.subscribe(() => {});
  expect(readerRefreshRows(client, "viewer", projection).map(row => row.publicationId)).toEqual([subscribed.publicationId, folder.publicationId]);
  expect(readerRefreshRows(client, "other-viewer", projection)).toEqual([]);
  unsubscribe(); client.clear();
});
