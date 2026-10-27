import { afterEach, expect, it, spyOn } from "bun:test";
import { InfiniteQueryObserver, QueryClient, type InfiniteData } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { EntriesPage } from "@/hooks/useEntries";
import * as appView from "@/lib/thinAppViewClient";
import { refreshAggregateFeed } from "@/lib/refreshAggregateFeed";
import { advanceFeedRefreshRevision, recordReadEntryMutations } from "@/lib/feedRefreshCoordinator";

const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
const key = ["aggregateEntries", "did:plc:viewer", "subscribed", "", "all"];
const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
const entry = (entryId: string) => ({ entryId, title: entryId, publishedAt: "2026-10-26T00:00:00Z" });
const initial: InfiniteData<EntriesPage> = { pages: [{ entries: [entry("head")], cursor: "tail" }, { entries: [entry("tail")], cursor: "more" }], pageParams: [undefined, "tail"] };
const restores: (() => void)[] = [];
afterEach(() => { restores.splice(0).reverse().forEach(restore => restore()); client.clear(); });
const refresh = (extra: Partial<Parameters<typeof refreshAggregateFeed>[0]> = {}) => refreshAggregateFeed({ queryClient: client, queryKey: key, feed: { kind: "subscribed" }, filter: "all", oauthSession: oauth, isCurrentSession: () => true, ...extra });

it("preserves loaded history and cancels pagination before merging the fresh head", async () => {
  client.setQueryData(key, initial);
  let finish!: (page: EntriesPage) => void;
  const observer = new InfiniteQueryObserver(client, { queryKey: key, initialPageParam: undefined as string | undefined, getNextPageParam: (page: EntriesPage) => page.cursor, staleTime: Infinity, queryFn: () => new Promise<EntriesPage>(resolve => { finish = resolve; }) });
  restores.push(observer.subscribe(() => {}));
  const pending = observer.fetchNextPage();
  const fetch = spyOn(appView, "listAggregateFeedFromAppView").mockResolvedValue({ entries: [entry("new")], cursor: "fresh" });
  restores.push(() => fetch.mockRestore());
  await refresh(); finish({ entries: [entry("stale")], cursor: "stale" }); await pending;
  const data = client.getQueryData<InfiniteData<EntriesPage>>(key)!;
  expect(data.pages.flatMap(page => page.entries.map(item => item.entryId))).toEqual(["new", "head", "tail"]);
  expect(data.pageParams).toEqual(initial.pageParams);
});

it("does not overwrite read confirmation or a replaced OAuth session", async () => {
  for (const change of ["revision", "read", "session"] as const) {
    client.setQueryData(key, initial);
    let finish!: (page: EntriesPage) => void;
    let started!: () => void;
    const requested = new Promise<void>(resolve => { started = resolve; });
    const fetch = spyOn(appView, "listAggregateFeedFromAppView").mockImplementation(() => new Promise(resolve => { finish = resolve; started(); }));
    restores.push(() => fetch.mockRestore());
    let current = true;
    const pending = refresh({ isCurrentSession: () => current });
    await requested;
    if (change === "revision") advanceFeedRefreshRevision(client, key);
    else if (change === "read") recordReadEntryMutations(client, oauth, ["head"]);
    else current = false;
    finish({ entries: [entry("stale") ] }); await pending;
    expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(initial);
    fetch.mockRestore();
  }
});

it("leaves cached rows intact when refresh fails or is aborted", async () => {
  client.setQueryData(key, initial);
  const fetch = spyOn(appView, "listAggregateFeedFromAppView").mockRejectedValue(new Error("offline"));
  restores.push(() => fetch.mockRestore());
  await expect(refresh()).rejects.toThrow("offline");
  const controller = new AbortController(); controller.abort();
  await expect(refresh({ signal: controller.signal })).rejects.toThrow();
  expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(initial);
});

it("settles on cancellation even if transport ignores the signal and never writes late data", async () => {
  client.setQueryData(key, initial);
  let finish!: (page: EntriesPage) => void;
  let started!: () => void;
  const requested = new Promise<void>(resolve => { started = resolve; });
  const fetch = spyOn(appView, "listAggregateFeedFromAppView").mockImplementation(() => new Promise(resolve => { finish = resolve; started(); }));
  restores.push(() => fetch.mockRestore());
  const controller = new AbortController();
  const pending = refresh({ signal: controller.signal });
  await requested;
  controller.abort();
  await expect(pending).rejects.toHaveProperty("name", "AbortError");
  finish({ entries: [entry("late")] });
  await Promise.resolve();
  expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(initial);
});
