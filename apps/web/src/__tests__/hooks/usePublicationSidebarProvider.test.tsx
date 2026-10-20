import { afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";

import { PublicationSidebarProvider, useSidebarBootstrap } from "@/contexts/PublicationSidebarContext";
import * as auth from "@/hooks/useAuth";
import * as bootstrapClient from "@/lib/bootstrapStreamClient";
import * as imageCache from "@/lib/imageBlobCache";
import * as projectionClient from "@/lib/publicationProjectionClient";
import * as readerFeeds from "@/lib/refreshReaderFeeds";
import * as publicationSources from "@/lib/refreshPublicationSources";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

let viewerSequence = 0;
function mountProvider() {
  const did = `did:plc:sidebar-test-${++viewerSequence}`;
  const oauthSession = { did } as OAuthSession;
  const authState = {
    session: { did }, getOAuthSession: () => oauthSession, oauthSessionReloadSeq: 0,
  } as unknown as ReturnType<typeof auth.useAuth>;
  spyOn(auth, "useAuth").mockReturnValue(authState);
  spyOn(imageCache, "prefetchCachedImages").mockImplementation(() => undefined);
  const projection: projectionClient.PublicationSidebarProjection = {
    viewerDid: did, folders: [], publicationPrefs: [], allPublicationRows: [],
    myPublications: [], subscribedUnfoldered: [], followingTabPublications: [],
    enrollAuthorDids: [], refreshedAt: "2026-10-20T00:00:00Z",
  };
  const stream = spyOn(bootstrapClient, "consumeBootstrapStream").mockImplementation(async ({ handlers }) => {
    handlers.onEvent({ kind: "sidebarPriority", payload: projection });
    handlers.onEvent({ kind: "done", payload: { refreshedAt: projection.refreshedAt } });
  });
  const post = spyOn(projectionClient, "refreshPublicationSidebar").mockResolvedValue(projection);
  const sources = spyOn(publicationSources, "refreshPublicationSources").mockResolvedValue(undefined);
  const feeds = spyOn(readerFeeds, "refreshReaderFeeds").mockResolvedValue({ newArticleCount: 0 });
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  function wrapper({ children }: { children: ReactNode }) {
    return (
      <QueryClientProvider client={queryClient}>
        <PublicationSidebarProvider>{children}</PublicationSidebarProvider>
      </QueryClientProvider>
    );
  }
  return { ...renderHook(() => useSidebarBootstrap(), { wrapper }), did, projection, queryClient, stream, post, sources, feeds };
}

afterEach(() => { cleanup(); mock.restore(); });

describe("PublicationSidebarProvider", () => {
  it("starts a single bootstrap stream per provider mount", async () => {
    const { result, stream } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    expect(stream).toHaveBeenCalledTimes(1);
  });

  it("coalesces manual refreshes and waits for ingestion before fetching feeds", async () => {
    const { result, projection, stream, post, sources, feeds } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    const posted = deferred();
    const bootstrapped = deferred();
    const ingested = deferred();
    const fetched = deferred();
    const order: string[] = [];
    post.mockImplementation(async () => { order.push("post"); await posted.promise; return projection; });
    stream.mockImplementation(async ({ handlers }) => {
      order.push("bootstrap");
      await bootstrapped.promise;
      handlers.onEvent({ kind: "done", payload: { refreshedAt: projection.refreshedAt } });
    });
    sources.mockImplementation(async ({ onProgress, onBatch }) => {
      order.push("sources");
      onProgress(0, 1);
      await ingested.promise;
      order.push("ingested");
      await onBatch();
      onProgress(1, 1);
    });
    feeds.mockImplementation(async () => {
      order.push("feeds");
      if (feeds.mock.calls.length === 1) return { newArticleCount: 2 };
      await fetched.promise;
      return { newArticleCount: 0 };
    });
    let first!: Promise<void>;
    let duplicate!: Promise<void>;
    act(() => {
      first = result.current.refresh.mutateAsync();
      duplicate = result.current.refresh.mutateAsync();
    });
    await waitFor(() => expect(result.current.refreshMessage).toBe("Checking Publications…"));
    expect(post).toHaveBeenCalledTimes(1);
    expect(stream).toHaveBeenCalledTimes(1);
    expect(sources).not.toHaveBeenCalled();
    expect(feeds).not.toHaveBeenCalled();
    await act(async () => { posted.resolve(); });
    await waitFor(() => expect(stream).toHaveBeenCalledTimes(2));
    expect(sources).not.toHaveBeenCalled();
    expect(feeds).not.toHaveBeenCalled();
    await act(async () => { bootstrapped.resolve(); });
    await waitFor(() => expect(result.current.refreshMessage).toBe("Checking for New Articles… 0 of 1"));
    expect(feeds).not.toHaveBeenCalled();
    await act(async () => { ingested.resolve(); });
    await waitFor(() => expect(result.current.refreshMessage).toBe("Updating Articles…"));
    expect(result.current.refresh.isPending).toBe(true);
    await act(async () => { fetched.resolve(); await Promise.all([first, duplicate]); });
    await waitFor(() => expect(result.current.refresh.isSuccess).toBe(true));
    expect(result.current.refreshMessage).toBe("2 New Articles Loaded");
    expect(sources).toHaveBeenCalledTimes(1);
    expect(order).toEqual(["post", "bootstrap", "sources", "ingested", "feeds", "feeds"]);
    expect(post.mock.calls[0]?.[1]?.aborted).toBe(false);
    expect(feeds.mock.calls[0]?.[0].signal).toBe(sources.mock.calls[0]?.[0].signal);
  });

  for (const stage of ["post", "bootstrap"] as const) {
    it(`settles a stalled ${stage} phase when its transport ignores cancellation`, async () => {
      const { result, post, stream, sources, feeds, rerender } = mountProvider();
      await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
      const started = deferred();
      const stalled = async () => { started.resolve(); return new Promise<never>(() => {}); };
      if (stage === "post") post.mockImplementation(stalled);
      else stream.mockImplementation(stalled);
      let pending!: Promise<void>;
      act(() => { pending = result.current.refresh.mutateAsync(); });
      const outcome = pending.then(() => "success", () => "cancelled");
      await started.promise;
      const authState = auth.useAuth();
      spyOn(auth, "useAuth").mockReturnValue({ ...authState, oauthSessionReloadSeq: 1 });
      let settled: string | undefined;
      await act(async () => { rerender(); settled = await outcome; });
      expect(settled).toBe("cancelled");
      expect(sources).not.toHaveBeenCalled();
      expect(feeds).not.toHaveBeenCalled();
    });
  }

  it("preserves the current selection and paginated cache during a manual bootstrap", async () => {
    const { result, stream, queryClient, did, projection } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    const publicationId = "did:plc:publication";
    const key = ["entries", did, publicationId, "all"];
    const cached = { pages: [{ entries: [], cursor: "tail" }, { entries: [] }], pageParams: [undefined, "tail"] };
    queryClient.setQueryData(key, cached);
    stream.mockImplementation(async ({ handlers }) => {
      handlers.onEvent({ kind: "selectedPublication", payload: { publicationId } });
      handlers.onEvent({ kind: "entriesPage", payload: { publicationId, entries: [], source: "live_projection" } });
      handlers.onEvent({ kind: "done", payload: { refreshedAt: projection.refreshedAt } });
    });
    await act(async () => { await result.current.refresh.mutateAsync(); });
    expect(result.current.streamSelectedPublicationId).toBeNull();
    expect(queryClient.getQueryData<typeof cached>(key)).toEqual(cached);
  });

  it("reports Refresh Complete when no new articles are loaded", async () => {
    const { result } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    await act(async () => { await result.current.refresh.mutateAsync(); });
    await waitFor(() => expect(result.current.refresh.isSuccess).toBe(true));
    expect(result.current.refreshMessage).toBe("Refresh Complete");
  });

  for (const failure of ["warning", "error", "onError", "throw", "truncated"] as const) {
    it(`fails manual refresh for a ${failure} bootstrap stream`, async () => {
      const { result, stream, sources, feeds } = mountProvider();
      await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
      const message = "Publication source unavailable";
      stream.mockImplementation(async ({ handlers }) => {
        if (failure === "throw") throw new Error(message);
        if (failure === "onError") handlers.onError?.(new Error(message));
        if (failure === "warning" || failure === "error") handlers.onEvent({ kind: failure, payload: { message } });
        if (failure !== "truncated") handlers.onEvent({ kind: "done", payload: { refreshedAt: "2026-10-20T00:00:01Z" } });
      });
      await act(async () => {
        await expect(result.current.refresh.mutateAsync()).rejects.toThrow(
          failure === "truncated" ? "Publication refresh ended before completion" : message,
        );
      });
      await waitFor(() => expect(result.current.refresh.isError).toBe(true));
      expect(result.current.refresh.isSuccess).toBe(false);
      expect(result.current.refreshMessage).not.toBe("Refresh Complete");
      expect(sources).not.toHaveBeenCalled();
      expect(feeds).not.toHaveBeenCalled();
    });
  }

  for (const phase of ["post", "bootstrap", "sources"] as const) {
    it(`aborts on account unmount during ${phase} without subsequent cache work`, async () => {
      const { result, unmount, did, projection, queryClient, stream, post, sources, feeds } = mountProvider();
      await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
      const pending = deferred();
      let signal: AbortSignal | undefined;
      if (phase === "post") post.mockImplementation(async (_oauth, currentSignal) => {
        signal = currentSignal;
        await pending.promise;
        return projection;
      });
      if (phase === "bootstrap") stream.mockImplementation(async (args) => {
        signal = args.signal;
        await pending.promise;
        args.handlers.onEvent({ kind: "sidebarPriority", payload: { ...projection, refreshedAt: "late event after unmount" } });
        args.handlers.onEvent({ kind: "done", payload: { refreshedAt: "late event after unmount" } });
      });
      if (phase === "sources") sources.mockImplementation(async (args) => {
        signal = args.signal;
        await pending.promise;
        await args.onBatch();
      });
      let outcome!: Promise<unknown>;
      act(() => {
        // Attach before cancellation so rejection cannot escape as unhandled.
        outcome = result.current.refresh.mutateAsync().catch((error: unknown) => error);
      });
      await waitFor(() => expect(signal).toBeDefined());
      const snapshot = queryClient.getQueryData<projectionClient.PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did));
      const setQueryData = spyOn(queryClient, "setQueryData");
      unmount();
      expect(signal?.aborted).toBe(true);
      pending.resolve();
      const error = await outcome;
      expect(error).toBeInstanceOf(DOMException);
      expect((error as DOMException).name).toBe("AbortError");
      expect(feeds).not.toHaveBeenCalled();
      if (phase === "post") expect(stream).toHaveBeenCalledTimes(1);
      if (phase !== "sources") expect(sources).not.toHaveBeenCalled();
      expect(setQueryData).not.toHaveBeenCalled();
      expect(queryClient.getQueryData<projectionClient.PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did))).toBe(snapshot);
    });
  }
});
