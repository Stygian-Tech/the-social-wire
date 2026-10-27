import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { QueryClient, QueryClientProvider, type InfiniteData } from "@tanstack/react-query";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";

import * as Auth from "@/hooks/useAuth";
import { ENTRIES_QUERY_KEY, useAggregateFeedEntries, type EntriesPage } from "@/hooks/useEntries";
import * as AppView from "@/lib/thinAppViewClient";
import * as Telemetry from "@/lib/clientPerformanceTelemetry";
import { refreshPublicationFeedFirstPage } from "@/lib/feedRefresh";
import { advanceFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}
const page = (id: string): EntriesPage => ({ entries: [{ entryId: id, title: id, publishedAt: "2026-10-20T00:00:00Z" }] });
const data = (id: string): InfiniteData<EntriesPage> => ({ pages: [page(id)], pageParams: [undefined] });
const viewerDid = "did:plc:revision-ordering";
const oauth = { did: viewerDid } as unknown as OAuthSession;
const publicationKey = "did:plc:publication";
const queryKey = [...ENTRIES_QUERY_KEY(viewerDid, publicationKey), "unread"];
let client: QueryClient;
const restores: (() => void)[] = [];

beforeEach(() => {
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockReturnValue({
    session: { did: viewerDid }, getOAuthSession: () => oauth, oauthSessionReloadSeq: 0,
  } as unknown as ReturnType<typeof Auth.useAuth>);
  const enabled = spyOn(AppView, "isThinAppViewEnabled").mockReturnValue(true);
  const telemetry = spyOn(Telemetry, "recordClientPerformance").mockResolvedValue(new Response(null, { status: 202 }));
  restores.push(() => auth.mockRestore(), () => enabled.mockRestore(), () => telemetry.mockRestore());
});
afterEach(() => {
  cleanup();
  client.clear();
  restores.splice(0).reverse().forEach(restore => restore());
});
function wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}
function mockFeed() {
  const response = deferred<EntriesPage>();
  const fetch = spyOn(AppView, "listAggregateFeedFromAppView").mockImplementation(() => response.promise);
  const counts = spyOn(AppView, "fetchAppViewUnreadCounts").mockResolvedValue({ counts: {} });
  restores.push(() => fetch.mockRestore(), () => counts.mockRestore());
  return { response, fetch, counts };
}

it("rejects a late background Unread response after manual refresh writes newer data", async () => {
  client.setQueryData(queryKey, data("cached"));
  const { response, counts } = mockFeed();
  const pending = refreshPublicationFeedFirstPage({ queryClient: client, publicationKey, viewerDid, oauthSession: oauth, articleFilter: "unread" });
  advanceFeedRefreshRevision(client, queryKey);
  client.setQueryData(queryKey, data("manual"));
  response.resolve(page("old-background"));
  expect(await pending).toBe(false);
  expect(client.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toEqual(data("manual"));
  expect(counts).not.toHaveBeenCalled();
});

it("starts a newer publication refresh without joining obsolete in-flight work", async () => {
  client.setQueryData(queryKey, data("cached"));
  const { response, fetch } = mockFeed();
  const args = { queryClient: client, publicationKey, viewerDid, oauthSession: oauth, articleFilter: "unread" as const };
  const pending = refreshPublicationFeedFirstPage(args);
  advanceFeedRefreshRevision(client, queryKey);
  fetch.mockResolvedValue(page("new"));
  expect(await refreshPublicationFeedFirstPage(args)).toBe(true);
  expect(fetch).toHaveBeenCalledTimes(2);
  response.resolve(page("old"));
  expect(await pending).toBe(false);
  expect(client.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toEqual(data("new"));
});

it("returns false when a revision changes during the background count update", async () => {
  client.setQueryData(queryKey, data("cached"));
  const { response, counts } = mockFeed();
  const badge = deferred<{ counts: Record<string, number> }>();
  counts.mockImplementation(() => badge.promise);
  const pending = refreshPublicationFeedFirstPage({ queryClient: client, publicationKey, viewerDid, oauthSession: oauth, articleFilter: "unread" });
  response.resolve(page("background"));
  await waitFor(() => expect(counts).toHaveBeenCalledTimes(1));
  advanceFeedRefreshRevision(client, queryKey);
  client.setQueryData(queryKey, data("manual"));
  badge.resolve({ counts: {} });
  expect(await pending).toBe(false);
  expect(client.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toEqual(data("manual"));
});

it("releases publication singleflight when unread badge transport ignores cancellation", async () => {
  client.setQueryData(queryKey, data("cached"));
  const { fetch, counts } = mockFeed();
  fetch.mockResolvedValue(page("fresh"));
  const badge = deferred<{ counts: Record<string, number> }>();
  counts.mockReturnValue(badge.promise);
  const controller = new AbortController();
  const args = { queryClient: client, publicationKey, viewerDid, oauthSession: oauth, articleFilter: "unread" as const };
  const pending = refreshPublicationFeedFirstPage({ ...args, signal: controller.signal });
  await waitFor(() => expect(counts).toHaveBeenCalledTimes(1));
  controller.abort();
  await expect(pending).rejects.toHaveProperty("name", "AbortError");
  counts.mockResolvedValue({ counts: {} });
  expect(await refreshPublicationFeedFirstPage(args)).toBe(true);
  expect(fetch).toHaveBeenCalledTimes(2);
  badge.resolve({ counts: { [publicationKey]: 99 } });
});

it("guards the aggregate custom refetch write and allows the next revision to finish", async () => {
  const feed = { kind: "following" as const };
  const key = ["aggregateEntries", viewerDid, feed.kind, "", "unread"];
  client.setQueryData(key, data("cached"));
  const { response, fetch } = mockFeed();
  const { result } = renderHook(() => useAggregateFeedEntries(feed, "unread"), { wrapper });
  let pending!: Promise<void>;
  act(() => { pending = result.current.refetch(); });
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  advanceFeedRefreshRevision(client, key);
  fetch.mockResolvedValue(page("new"));
  await act(async () => { await result.current.refetch(); });
  await act(async () => { response.resolve(page("old")); await pending; });
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 0)); });
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(data("new"));
});

it("guards the aggregate restored-cache write after cancelling the normal query", async () => {
  const feed = { kind: "following" as const };
  const key = ["aggregateEntries", viewerDid, feed.kind, "", "unread"];
  client.setQueryData(key, data("cached"), { updatedAt: Date.now() - 60_000 });
  const { response, fetch } = mockFeed();
  renderHook(() => useAggregateFeedEntries(feed, "unread"), { wrapper });
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  await act(async () => {
    advanceFeedRefreshRevision(client, key);
    await client.cancelQueries({ queryKey: key, exact: true });
    client.setQueryData(key, data("manual"));
    response.resolve(page("old"));
    await response.promise;
  });
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 0)); });
  expect(client.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(data("manual"));
});
