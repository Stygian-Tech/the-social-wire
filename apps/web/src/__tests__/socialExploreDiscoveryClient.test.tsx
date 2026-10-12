import { afterEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { ModerationOpts } from "@atproto/api";
import * as Network from "@/lib/atprotoNetwork";
import * as Client from "@/lib/socialExploreDiscoveryClient";
import * as Session from "@/hooks/useSocialWorkspace";
import { useSocialExploreDiscovery } from "@/hooks/useSocialExploreDiscovery";

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
function restore(spy: { mockRestore(): void }) { restores.push(() => spy.mockRestore()); }
const safety = (did: string): ModerationOpts => ({ userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } });
it("uses configured public AppView without viewer identity, OAuth or added grants", async () => {
  restore(spyOn(Network, "getAtprotoNetwork").mockReturnValue({ publicAppView: "https://local.test", plcDirectory: "https://plc.test", handleResolver: "https://local.test", appViewDid: "did:web:local.test", appLabelers: [] }));
  const controller = new AbortController();
  const response = { topics: [{ topic: "Space", description: "A new mission launches.", link: "/search?q=space" }], suggested: [{ topic: "Science", description: "New discoveries.", link: "/search?q=science" }] };
  const fetch = spyOn(globalThis, "fetch").mockImplementation(Object.assign(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    expect(url.origin).toBe("https://local.test");
    expect(url.searchParams.has("viewer")).toBe(false);
    const headers = new Headers(init?.headers);
    expect(headers.has("authorization")).toBe(false); expect(headers.has("atproto-proxy")).toBe(false);
    expect(init?.signal).toBe(controller.signal);
    return Response.json(url.pathname.endsWith("getTrendingTopics") ? response : { feeds: [] });
  }, { preconnect: globalThis.fetch.preconnect })); restore(fetch);
  expect(await Client.getSocialTrendingTopics(controller.signal)).toEqual(response);
  expect(fetch).toHaveBeenCalledTimes(1);
});
it("preserves unsupported service errors rather than reporting an empty successful section", async () => {
  restore(spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ error: "NotImplemented", message: "Unsupported" }, { status: 501 })));
  await expect(Client.getSocialTrendingTopics()).rejects.toMatchObject({ status: 501 });
});
it("scopes recommendation caches per account and cancels prior discovery on account change", async () => {
  let did = "did:plc:alice";
  restore(spyOn(Session, "useSocialWorkspaceSession").mockImplementation(() => ({ did, sequence: 0, requireSession: () => ({ did }) as import("@atproto/oauth-client-browser").OAuthSession })));
  const aborts: AbortSignal[] = [];
  restore(spyOn(Client, "getSocialTrendingTopics").mockImplementation(async signal => {
    aborts.push(signal!);
    return did.endsWith("alice") ? { topics: [{ topic: "Alice Topic", link: "" }], suggested: [] } : new Promise(() => {});
  }));
  restore(spyOn(Client, "getSocialRecommendedFeeds").mockImplementation(async (_session, moderation) => {
    if (moderation.userDid?.endsWith("alice")) return [];
    return new Promise(() => {});
  }));
  const cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={cache}>{children}</QueryClientProvider>;
  const view = renderHook(() => useSocialExploreDiscovery(safety(did), true), { wrapper });
  await waitFor(() => expect(view.result.current.topics.data?.topics[0]?.topic).toBe("Alice Topic"));
  did = "did:plc:bob"; view.rerender();
  expect(view.result.current.topics.data).toBeUndefined();
  expect(view.result.current.feeds.data).toBeUndefined();
  await act(async () => { view.unmount(); });
  expect(aborts[1]?.aborted).toBe(true);
  cache.clear();
});
it("never requests feed recommendations before matching viewer moderation is available", () => {
  restore(spyOn(Session, "useSocialWorkspaceSession").mockReturnValue({ did: "did:plc:alice", sequence: 0, requireSession: () => { throw new Error("No writes expected"); } }));
  const topics = spyOn(Client, "getSocialTrendingTopics").mockResolvedValue({ topics: [], suggested: [] }); restore(topics);
  const feeds = spyOn(Client, "getSocialRecommendedFeeds").mockResolvedValue([]); restore(feeds);
  const cache = new QueryClient();
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={cache}>{children}</QueryClientProvider>;
  renderHook(() => useSocialExploreDiscovery(safety("did:plc:bob"), true), { wrapper });
  expect(feeds).not.toHaveBeenCalled();
  cache.clear();
});

it("recommended feeds reuse the existing authenticated viewer service and reject mismatched safety", async () => {
  const did = "did:plc:alice";
  const session = { did, fetchHandler: async (_path: string, init?: RequestInit) => {
    expect(new Headers(init?.headers).get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
    return Response.json({ feeds: [] });
  } } as unknown as import("@atproto/oauth-client-browser").OAuthSession;
  expect(await Client.getSocialRecommendedFeeds(session, safety(did))).toEqual([]);
  await expect(Client.getSocialRecommendedFeeds(session, safety("did:plc:bob"))).rejects.toThrow("account changed");
});
