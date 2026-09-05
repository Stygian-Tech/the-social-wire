import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";
import { FeedResponseError } from "@/lib/feedResponseError";
import { WIRE_MODERATION_RPC_SCOPES } from "@/lib/atprotoOAuthScopes";
import { useWireFeedEntries } from "@/hooks/useWireFeed";
import { useWireEdition } from "@/hooks/useWireEdition";
import { useCircleEdition } from "@/hooks/useCircleFeed";
import type { WirePage } from "@/lib/wireFeedClient";
import type { WireEditionPage } from "@/lib/wireEditionClient";
import type { CircleEditionPage } from "@/lib/circleFeedClient";

const realAuth = { ...await import("@/hooks/useAuth") };
const realWire = { ...await import("@/lib/wireFeedClient") };
const realEdition = { ...await import("@/lib/wireEditionClient") };
const realCircle = { ...await import("@/lib/circleFeedClient") };
let oauth: OAuthSession | null;
let queryClient: QueryClient;
let wireHandler: typeof realWire.getWire;
let editionHandler: typeof realEdition.getWireEdition;
let circleHandler: typeof realCircle.getCircleEdition;
const requests: Array<{ feed: string; cursor?: string; did?: string; refresh?: boolean }> = [];
const catalog = { enabled: true, available: true, title: "The Wire", subtitle: "", supportedLanguages: ["en"] };

function session(did: string): OAuthSession {
  return { did, getTokenInfo: async () => ({ scope: WIRE_MODERATION_RPC_SCOPES.join(" ") }) } as unknown as OAuthSession;
}
function wirePage(generationId: string, cursor?: string): WirePage {
  return { generationId, cursor, generatedAt: "2026-09-05T00:00:00Z", language: "en", source: "ranked", degraded: false,
    items: [{ itemId: generationId, title: generationId, canonicalUrl: `https://example.com/${generationId}`,
      source: { name: "Example", domain: "example.com" }, reasons: [], provenance: [] }] };
}
function edition(generationId: string, moreCursor?: string): WireEditionPage {
  return { ...wirePage(generationId), editionVersion: "1", stories: wirePage(generationId).items,
    moreCursor, topStoryIds: [generationId], publicationSpotlights: [], storyRails: [], people: [], trendingStoryIds: [] };
}
function circle(generationId: string, moreCursor?: string): CircleEditionPage {
  return { ...edition(generationId, moreCursor), stories: [{ storyId: generationId, title: generationId,
    canonicalUrl: `https://example.com/${generationId}`, source: { name: "Example", domain: "example.com" },
    reasons: [], discussionCount: 0, sharerCount: 0, sharers: [] }] };
}
function expired(): FeedResponseError { return new FeedResponseError("Generation expired", "CursorExpired", 410); }
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
function wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
}

beforeEach(() => {
  oauth = session("did:plc:alice");
  requests.length = 0;
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  mock.module("@/hooks/useAuth", () => ({ ...realAuth, useAuth: () => ({
    session: oauth ? { did: oauth.did } : null, isLoading: false, oauthSessionReloadSeq: 0, getOAuthSession: () => oauth,
  }) }));
  mock.module("@/lib/wireFeedClient", () => ({ ...realWire,
    selectWireLanguage: () => "en", selectWireViewerRegion: () => undefined,
    getWireFeedCatalog: async () => catalog,
    createWireModerationDpopProofPool: async () => "proofs",
    getWire: async (args: Parameters<typeof realWire.getWire>[0] = {}) => {
      requests.push({ feed: "wire", cursor: args.cursor, did: args.oauthSession?.did });
      return wireHandler(args);
    },
  }));
  mock.module("@/lib/wireEditionClient", () => ({ ...realEdition,
    getWireEdition: async (args: Parameters<typeof realEdition.getWireEdition>[0] = {}) => {
      requests.push({ feed: "edition", did: args.oauthSession?.did, refresh: args.bypassCache });
      return editionHandler(args);
    },
  }));
  mock.module("@/lib/circleFeedClient", () => ({ ...realCircle,
    getCircleCatalog: async () => catalog,
    getCircleEdition: async (args: Parameters<typeof realCircle.getCircleEdition>[0]) => {
      requests.push({ feed: "circle", cursor: args.cursor, did: args.oauthSession.did, refresh: args.bypassCache });
      return circleHandler(args);
    },
  }));
});
afterEach(() => {
  cleanup();
  queryClient.clear();
  mock.module("@/hooks/useAuth", () => realAuth);
  mock.module("@/lib/wireFeedClient", () => realWire);
  mock.module("@/lib/wireEditionClient", () => realEdition);
  mock.module("@/lib/circleFeedClient", () => realCircle);
});

describe("Mounted discovery cursor recovery", () => {
  it("replaces Wire pages and cursor after an expired next-page response", async () => {
    let initial = true;
    wireHandler = async (args = {}) => {
      if (args.cursor) throw expired();
      const result = initial ? wirePage("old", "expired") : wirePage("fresh", "new-cursor");
      initial = false;
      return result;
    };
    const { result } = renderHook(() => useWireFeedEntries({ enabled: true }), { wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("old"));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(result.current.data?.pages.map(page => page.generationId)).toEqual(["fresh"]));
    expect(result.current.data?.pageParams).toEqual([undefined]);
    expect(result.current.data?.pages[0]?.cursor).toBe("new-cursor");
    expect(requests.filter(request => request.feed === "wire").map(request => request.cursor)).toEqual([undefined, "expired", undefined]);
  });

  it("refreshes the Wire edition and clears old More stories after cursor expiry", async () => {
    editionHandler = async (args = {}) => args.bypassCache ? edition("fresh", "new-cursor") : edition("old", "first-more");
    wireHandler = async (args = {}) => {
      if (args.cursor === "first-more") return wirePage("old-tail", "expired");
      throw expired();
    };
    const { result } = renderHook(() => useWireEdition({ enabled: true }), { wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("old"));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(result.current.moreStories).toHaveLength(1));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("fresh"));
    expect(result.current.moreStories).toEqual([]);
    expect(requests.filter(request => request.feed === "edition" && request.refresh)).toHaveLength(1);
  });

  it("retains Circle pages and never retries a failed automatic refresh in a loop", async () => {
    const offline = new Error("Offline");
    circleHandler = async (args) => {
      if (args.bypassCache) throw offline;
      if (args.cursor) throw expired();
      return circle("old", "expired");
    };
    const { result, rerender } = renderHook(() => useCircleEdition({ enabled: true }), { wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("old"));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(result.current.error).toBe(offline));
    rerender();
    await act(async () => { await new Promise(resolve => setTimeout(resolve, 30)); });
    expect(result.current.data?.pages.map(page => page.generationId)).toEqual(["old"]);
    expect(requests.filter(request => request.refresh)).toHaveLength(1);
  });

  it("does not publish Alice's delayed Circle recovery into Bob's cache", async () => {
    const pending = deferred<CircleEditionPage>();
    circleHandler = async (args) => {
      if (args.bypassCache) return pending.promise;
      if (args.cursor) throw expired();
      return circle(args.oauthSession.did === "did:plc:alice" ? "alice-old" : "bob-current", "expired");
    };
    const { result, rerender } = renderHook(() => useCircleEdition({ enabled: true }), { wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("alice-old"));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(requests.filter(request => request.refresh)).toHaveLength(1));
    oauth = session("did:plc:bob");
    rerender();
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("bob-current"));
    await act(async () => { pending.resolve(circle("alice-private")); });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("bob-current"));
    expect(queryClient.getQueryData<{ pages: CircleEditionPage[] }>(["circleEdition", "did:plc:bob", "en", 0])?.pages[0]?.generationId).toBe("bob-current");
  });
  it("recovers Circle to one fresh generation after successful expiry refresh", async () => {
    circleHandler = async (args) => {
      if (args.bypassCache) return circle("fresh", "new-cursor");
      if (args.cursor) throw expired();
      return circle("old", "expired");
    };
    const { result } = renderHook(() => useCircleEdition({ enabled: true }), { wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("old"));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(result.current.data?.pages.map(page => page.generationId)).toEqual(["fresh"]));
    expect(result.current.data?.pageParams).toEqual([undefined]);
    expect(result.current.data?.pages[0]?.moreCursor).toBe("new-cursor");
    expect(requests.filter(request => request.refresh)).toHaveLength(1);
  });

  it("keeps Wire recovery tied to the initiating session and clears its pending status", async () => {
    const alice = oauth;
    const pending = deferred<WirePage>();
    let aliceFirstPages = 0;
    wireHandler = async (args = {}) => {
      if (args.cursor) throw expired();
      if (args.oauthSession?.did === "did:plc:alice") {
        if (++aliceFirstPages > 1) return pending.promise;
        return wirePage("alice-old", "expired");
      }
      return wirePage("bob-current");
    };
    const { result, rerender } = renderHook(() => useWireFeedEntries({ enabled: true }), { wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("alice-old"));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(aliceFirstPages).toBe(2));
    oauth = session("did:plc:bob");
    rerender();
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("bob-current"));
    await act(async () => { pending.resolve(wirePage("alice-private")); });
    expect(queryClient.getQueryData<{ pages: WirePage[] }>(["wireEntries", "en", "viewer:did:plc:bob"])?.pages[0]?.generationId).toBe("bob-current");
    oauth = alice;
    rerender();
    await waitFor(() => expect(result.current.isRefreshingFirstPage).toBe(false));
  });

  it("does not write a late Wire edition recovery after switching accounts", async () => {
    const pending = deferred<WireEditionPage>();
    editionHandler = async (args = {}) => {
      if (args.bypassCache) return pending.promise;
      return edition(args.oauthSession?.did === "did:plc:alice" ? "alice-old" : "bob-current", "expired");
    };
    wireHandler = async () => { throw expired(); };
    const { result, rerender } = renderHook(() => useWireEdition({ enabled: true }), { wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("alice-old"));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(requests.filter(request => request.feed === "edition" && request.refresh)).toHaveLength(1));
    oauth = session("did:plc:bob");
    rerender();
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("bob-current"));
    await act(async () => { pending.resolve(edition("alice-private")); });
    expect(queryClient.getQueryData<{ pages: WireEditionPage[] }>(["wireEdition", "en", "default", "viewer:did:plc:bob"])?.pages[0]?.generationId).toBe("bob-current");
    expect(result.current.isRefreshingFirstPage).toBe(false);
  });

  it("keeps cached Wire rows without looping when first-page recovery is offline", async () => {
    let firstPages = 0;
    wireHandler = async (args = {}) => {
      if (args.cursor) throw expired();
      if (++firstPages > 1) throw new Error("Offline");
      return wirePage("old", "expired");
    };
    const { result, rerender } = renderHook(() => useWireFeedEntries({ enabled: true }), { wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("old"));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(result.current.viewerModerationError).toBe(true));
    await waitFor(() => expect(result.current.isRefreshingFirstPage).toBe(false));
    rerender();
    await act(async () => { await new Promise(resolve => setTimeout(resolve, 30)); });
    expect(firstPages).toBe(2);
    expect(result.current.data?.pages.map(page => page.generationId)).toEqual(["old"]);
  });

  it("does not repopulate private Circle cache after sign-out during recovery", async () => {
    const pending = deferred<CircleEditionPage>();
    circleHandler = async (args) => {
      if (args.bypassCache) return pending.promise;
      if (args.cursor) throw expired();
      return circle("alice-old", "expired");
    };
    const { result, rerender } = renderHook(() => useCircleEdition({ enabled: true }), { wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.generationId).toBe("alice-old"));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(requests.filter(request => request.refresh)).toHaveLength(1));
    oauth = null;
    rerender();
    await act(async () => { queryClient.clear(); });
    await act(async () => { pending.resolve(circle("alice-private")); });
    expect(queryClient.getQueryData(["circleEdition", "did:plc:alice", "en", 0])).toBeUndefined();
    expect(result.current.data).toBeUndefined();
  });

});
