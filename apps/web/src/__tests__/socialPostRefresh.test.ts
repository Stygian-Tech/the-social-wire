import { afterEach, expect, it, spyOn } from "bun:test";
import { InfiniteQueryObserver, QueryClient, QueryObserver } from "@tanstack/react-query";
import { refreshSocialPostQueries } from "@/lib/socialPostRefresh";

const did = "did:plc:viewer";
const cleanups: (() => void)[] = [];
afterEach(() => cleanups.splice(0).reverse().forEach(cleanup => cleanup()));

function client() {
  const cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  cleanups.push(() => cache.clear());
  return cache;
}
async function settle() {
  for (let index = 0; index < 20; index++) await Promise.resolve();
}

it("preserves active and inactive timeline pages after publishing without fetching a newer head", async () => {
  const cache = client();
  const key = ["blueskySocial", did, "timeline", 0, "following"];
  cache.setQueryData(key, { pages: [{ feed: ["old"], cursor: "older" }, { feed: ["older"] }], pageParams: [undefined, "older"] });
  const original = cache.getQueryData(key);
  const inactiveKey = ["blueskySocial", did, "timeline", 0, "generator", "other-feed"];
  cache.setQueryData(inactiveKey, original);
  const cursors: unknown[] = [];
  const observer = new InfiniteQueryObserver(cache, {
    queryKey: key,
    staleTime: Infinity,
    initialPageParam: undefined as string | undefined,
    queryFn: async ({ pageParam }) => { cursors.push(pageParam); return { feed: ["new reply"] }; },
    getNextPageParam: () => undefined,
  });
  cleanups.push(observer.subscribe(() => {}));
  cleanups.push(refreshSocialPostQueries(cache, did, () => true));
  await settle();
  expect(cursors).toEqual([]);
  expect(cache.getQueryData<unknown>(key)).toBe(original);
  expect(cache.getQueryData<unknown>(inactiveKey)).toBe(original);
  expect(cache.getQueryState(key)?.isInvalidated).toBe(true);
});

it("still refreshes the active conversation after publishing", async () => {
  const cache = client();
  const key = ["blueskySocial", did, "thread", "post"];
  cache.setQueryData(key, "old thread");
  const observer = new QueryObserver(cache, { queryKey: key, staleTime: Infinity, queryFn: async () => "thread with new reply" });
  cleanups.push(observer.subscribe(() => {}));
  cleanups.push(refreshSocialPostQueries(cache, did, () => true));
  await settle();
  expect(cache.getQueryData<string>(key)).toBe("thread with new reply");
});

it("lets an in-flight initial timeline load complete when publishing refresh overlaps it", async () => {
  const cache = client();
  const key = ["blueskySocial", did, "timeline", 0, "following"];
  let complete!: (page: { feed: string[] }) => void;
  let signal!: AbortSignal;
  const observer = new InfiniteQueryObserver(cache, {
    queryKey: key,
    initialPageParam: undefined,
    queryFn: args => {
      signal = args.signal;
      return new Promise<{ feed: string[] }>(resolve => { complete = resolve; });
    },
    getNextPageParam: () => undefined,
  });
  cleanups.push(observer.subscribe(() => {}));
  cleanups.push(refreshSocialPostQueries(cache, did, () => true));
  await settle();
  expect(signal.aborted).toBe(false);
  expect(observer.getCurrentResult().fetchStatus).toBe("fetching");
  complete({ feed: ["initial post"] });
  await settle();
  expect(observer.getCurrentResult().status).toBe("success");
  expect(observer.getCurrentResult().data?.pages).toEqual([{ feed: ["initial post"] }]);
});

it("invalidates affected surfaces for the posting viewer without touching other accounts or catalog state", async () => {
  const cache = client();
  const surfaces = ["timeline", "profileTimeline", "thread", "explore", "bookmarks", "notifications"];
  for (const viewer of [did, "did:plc:other"]) {
    for (const surface of [...surfaces, "catalog"]) cache.setQueryData(["blueskySocial", viewer, surface], { value: surface });
  }
  cache.setQueryData(["unrelated", did, "thread"], "unrelated");
  cleanups.push(refreshSocialPostQueries(cache, did, () => true));
  await settle();
  for (const surface of surfaces) expect(cache.getQueryState(["blueskySocial", did, surface])?.isInvalidated).toBe(true);
  for (const surface of [...surfaces, "catalog"]) expect(cache.getQueryState(["blueskySocial", "did:plc:other", surface])?.isInvalidated).toBe(false);
  expect(cache.getQueryState(["blueskySocial", did, "catalog"])?.isInvalidated).toBe(false);
  expect(cache.getQueryState(["unrelated", did, "thread"])?.isInvalidated).toBe(false);
});

it("does not refresh an account that changed while earlier requests were being cancelled", async () => {
  const cache = client();
  let current = true;
  let cancelled!: () => void;
  const cancel = spyOn(cache, "cancelQueries").mockImplementation(() => new Promise(resolve => { cancelled = resolve; }));
  const invalidate = spyOn(cache, "invalidateQueries");
  cleanups.push(() => cancel.mockRestore(), () => invalidate.mockRestore());
  cleanups.push(refreshSocialPostQueries(cache, did, () => current));
  current = false;
  cancelled();
  await settle();
  expect(invalidate).not.toHaveBeenCalled();
});

it("retries indexing twice and cancels pending retries on composer cleanup", async () => {
  const cache = client();
  const timers: { callback: () => void; delay: number; cleared: boolean }[] = [];
  const timeout = spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void, delay: number) => {
    const timer = { callback, delay, cleared: false };
    timers.push(timer);
    return timer as unknown as ReturnType<typeof setTimeout>;
  }) as typeof setTimeout);
  const clear = spyOn(globalThis, "clearTimeout").mockImplementation(((timer: typeof timers[number]) => { timer.cleared = true; }) as unknown as typeof clearTimeout);
  const invalidate = spyOn(cache, "invalidateQueries").mockResolvedValue(undefined);
  cleanups.push(() => timeout.mockRestore(), () => clear.mockRestore(), () => invalidate.mockRestore());
  const stop = refreshSocialPostQueries(cache, did, () => true);
  await settle();
  expect(invalidate).toHaveBeenCalledTimes(1);
  expect(timers.map(timer => timer.delay)).toEqual([1_000, 3_000]);
  timers[0]!.callback();
  await settle();
  expect(invalidate).toHaveBeenCalledTimes(2);
  stop();
  expect(timers.every(timer => timer.cleared)).toBe(true);
  timers[1]!.callback();
  await settle();
  expect(invalidate).toHaveBeenCalledTimes(2);
});

it("skips refresh when the posting viewer is already gone", async () => {
  const cache = client();
  const invalidate = spyOn(cache, "invalidateQueries");
  cleanups.push(() => invalidate.mockRestore());
  cleanups.push(refreshSocialPostQueries(cache, did, () => false));
  await settle();
  expect(invalidate).not.toHaveBeenCalled();
});
