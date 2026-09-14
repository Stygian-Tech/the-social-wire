import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { QueryClient, type InfiniteData } from "@tanstack/react-query";

import { ENTRIES_QUERY_KEY, type EntriesPage } from "@/hooks/useEntries";
import { queueBootstrapFeedRefresh } from "@/hooks/useProactiveFeedRefresh";
import { writeStreamedEntriesPage } from "@/lib/bootstrapStreamState";
import { refreshPublicationFeedFirstPage } from "@/lib/feedRefresh";

const originalFetch = globalThis.fetch;
const originalEnvironment = { ...process.env };
const publicationKey = "rss:aHR0cHM6Ly9leGFtcGxlLnRlc3QvcnNz";
const viewerDid = "did:plc:bootstrap-cache-viewer";
const queryKey = [...ENTRIES_QUERY_KEY(viewerDid, publicationKey), "all"];
const page: EntriesPage = {
  entries: [{ entryId: "one", title: "One", publishedAt: "2026-01-01T00:00:00.000Z" }],
};

function oauthSession() {
  const nonces = new Map<string, string>();
  return {
    did: viewerDid,
    getTokenSet: async () => ({ access_token: "test-token", token_type: "DPoP" }),
    getTokenInfo: async () => ({ aud: "https://pds.example" }),
    fetchHandler: async () => {
      nonces.set("https://pds.example", "test-nonce");
      return new Response(JSON.stringify({ records: [] }), {
        headers: { "DPoP-Nonce": "test-nonce" },
      });
    },
    server: {
      dpopKey: {
        bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
        algorithms: ["ES256"],
        createJwt: async () => "test-proof",
      },
      dpopNonces: {
        get: async (origin: string) => nonces.get(origin),
        set: async (origin: string, nonce: string) => { nonces.set(origin, nonce); },
      },
      serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
    },
  } as never;
}

afterEach(() => {
  globalThis.fetch = originalFetch;
  process.env = { ...originalEnvironment };
});

describe("bootstrap feed recovery", () => {
  it("fetches a missing unavailable page through the normal feed query without invalidation", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://api.example.test";
    let requests = 0;
    globalThis.fetch = (async (url: string) => {
      expect(url).toContain("/xrpc/app.thesocialwire.appview.getFeed");
      expect(new URL(url).searchParams.get("id")).toBe(publicationKey);
      requests++;
      return new Response(JSON.stringify(page), {
        headers: { "Content-Type": "application/json" },
      });
    }) as unknown as typeof fetch;
    writeStreamedEntriesPage(queryClient, viewerDid, {
      publicationId: encodeURIComponent(publicationKey), entries: [], source: "unavailable",
    });
    const invalidation = spyOn(queryClient, "invalidateQueries");
    try {
      expect(await refreshPublicationFeedFirstPage({
        queryClient, publicationKey, viewerDid, oauthSession: oauthSession(), allowCacheMiss: true,
      })).toBe(true);
      expect(requests).toBe(1);
      expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toEqual({ pages: [page], pageParams: [undefined] });
      expect(invalidation).not.toHaveBeenCalled();
    } finally {
      invalidation.mockRestore();
      queryClient.clear();
    }
  });

  it("coalesces encoded/canonical bootstrap events with an in-flight normal feed fetch", async () => {
    const queryClient = new QueryClient();
    let complete!: (page: EntriesPage) => void;
    let requests = 0;
    const normalFetch = queryClient.fetchInfiniteQuery({
      queryKey,
      initialPageParam: undefined,
      queryFn: () => { requests++; return new Promise<EntriesPage>((resolve) => { complete = resolve; }); },
      getNextPageParam: () => undefined,
    });
    const callbacks: (() => void)[] = [];
    const timer = spyOn(window, "setTimeout").mockImplementation(((callback: TimerHandler) => {
      callbacks.push(callback as () => void);
      return 1;
    }) as typeof window.setTimeout);
    try {
      const args = { queryClient, viewerDid, publicationKey, oauthSession: oauthSession() };
      queueBootstrapFeedRefresh(args);
      queueBootstrapFeedRefresh({ ...args, publicationKey: encodeURIComponent(publicationKey) });
      expect(callbacks).toHaveLength(1);
      expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toBeUndefined();
      callbacks[0]!();
      queueBootstrapFeedRefresh(args);
      expect(callbacks).toHaveLength(1);
      expect(requests).toBe(1);
      complete(page);
      await normalFetch;
    } finally {
      timer.mockRestore();
    }
    expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toEqual({ pages: [page], pageParams: [undefined] });
    expect(requests).toBe(1);
    queryClient.clear();
  });

  it("keeps viewers isolated when they share a query client and publication", () => {
    const queryClient = new QueryClient();
    const otherViewer = "did:plc:other-bootstrap-viewer";
    const otherKey = [...ENTRIES_QUERY_KEY(otherViewer, publicationKey), "all"];
    queryClient.setQueryData(otherKey, { pages: [page], pageParams: [undefined] }, { updatedAt: 123 });
    const callbacks: (() => void)[] = [];
    const timer = spyOn(window, "setTimeout").mockImplementation(((callback: TimerHandler) => {
      callbacks.push(callback as () => void);
      return callbacks.length;
    }) as typeof window.setTimeout);
    try {
      const args = { queryClient, viewerDid, publicationKey, oauthSession: oauthSession() };
      queueBootstrapFeedRefresh(args);
      queueBootstrapFeedRefresh({ ...args, viewerDid: otherViewer });
      queueBootstrapFeedRefresh(args);
      expect(callbacks).toHaveLength(2);
      writeStreamedEntriesPage(queryClient, viewerDid, {
        publicationId: publicationKey, entries: [], source: "unavailable",
      });
      expect(queryClient.getQueryData(queryKey)).toBeUndefined();
      expect(queryClient.getQueryState(otherKey)?.dataUpdatedAt).toBe(123);
      expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(otherKey)?.pages[0]).toEqual(page);
    } finally {
      timer.mockRestore();
      queryClient.clear();
    }
  });

  it("does not seed empty success or automatically retry a failed cache-miss fetch", async () => {
    const queryClient = new QueryClient();
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://api.example.test";
    let requests = 0;
    globalThis.fetch = (async () => {
      requests++;
      return new Response(JSON.stringify({ error: "ServiceUnavailable" }), { status: 503 });
    }) as unknown as typeof fetch;
    const args = { queryClient, publicationKey, viewerDid, oauthSession: oauthSession(), allowCacheMiss: true };
    await expect(refreshPublicationFeedFirstPage(args)).rejects.toThrow();
    expect(requests).toBe(1);
    expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(queryKey)).toBeUndefined();
    expect(queryClient.getQueryState(queryKey)?.status).toBe("error");
    queryClient.clear();
  });
});
