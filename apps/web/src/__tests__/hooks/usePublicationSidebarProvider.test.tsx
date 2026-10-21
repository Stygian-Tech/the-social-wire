import { afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import { InfiniteQueryObserver, QueryClient, QueryClientProvider } from "@tanstack/react-query";
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
import * as readerUnread from "@/lib/refreshReaderUnreadCounts";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

let viewerSequence = 0;
function mountProvider(options: { initialError?: boolean; initialGate?: ReturnType<typeof deferred> } = {}) {
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
    if (options.initialGate) {
      await options.initialGate.promise;
      handlers.onEvent({ kind: "sidebarPriority", payload: projection });
    }
    if (options.initialError) handlers.onError?.(new Error("Initial bootstrap failed"));
    else handlers.onEvent({ kind: "done", payload: { refreshedAt: projection.refreshedAt } });
  });
  const post = spyOn(projectionClient, "refreshPublicationSidebar").mockResolvedValue(projection);
  const sources = spyOn(publicationSources, "refreshPublicationSources").mockImplementation(async ({ onBatch }) => { await onBatch(); });
  const unread = spyOn(readerUnread, "refreshReaderUnreadCounts").mockResolvedValue(undefined);
  const feeds = spyOn(readerFeeds, "refreshReaderFeeds").mockResolvedValue({ newArticleCount: 0 });
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  function wrapper({ children }: { children: ReactNode }) {
    return (
      <QueryClientProvider client={queryClient}>
        <PublicationSidebarProvider>{children}</PublicationSidebarProvider>
      </QueryClientProvider>
    );
  }
  return { ...renderHook(() => useSidebarBootstrap(), { wrapper }), did, projection, queryClient, stream, post, sources, feeds, unread };
}

afterEach(() => { cleanup(); mock.restore(); });

describe("PublicationSidebarProvider", () => {
  it("starts a single bootstrap stream per provider mount", async () => {
    const { result, stream } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    expect(stream).toHaveBeenCalledTimes(1);
  });

  it("coalesces manual refreshes, consumes the full POST, and waits for sources, feeds, and unread counts", async () => {
    const { result, projection, stream, post, sources, feeds, unread, queryClient, did } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    const posted = deferred(), ingested = deferred(), fetched = deferred(), counted = deferred();
    const order: string[] = [];
    const full = { ...projection, folders: [{ uri: "at://folder", rkey: "folder", value: { name: "Fresh Folder" } }], folderSections: [{ folderRkey: "folder", folderUri: "at://folder", publications: [] }] };
    post.mockImplementation(async () => { order.push("post"); await posted.promise; return full; });
    sources.mockImplementation(async ({ onProgress, onBatch }) => {
      order.push("sources"); onProgress(0, 78);
      await ingested.promise; order.push("ingested");
      onProgress(78, 78); await onBatch();
    });
    feeds.mockImplementation(async () => { order.push("feeds"); await fetched.promise; return { newArticleCount: 0 }; });
    unread.mockImplementation(async () => { order.push("counts"); await counted.promise; });
    let first!: Promise<void>, duplicate!: Promise<void>;
    act(() => { first = result.current.refresh.mutateAsync(); duplicate = result.current.refresh.mutateAsync(); });
    await waitFor(() => expect(post).toHaveBeenCalledTimes(1));
    expect(sources).not.toHaveBeenCalled();
    await act(async () => { posted.resolve(); });
    await waitFor(() => expect(result.current.refreshMessage).toBe("Checking 78 Publications…"));
    expect(stream).toHaveBeenCalledTimes(1);
    expect(queryClient.getQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did))).toMatchObject(full);
    expect(feeds).not.toHaveBeenCalled();
    await act(async () => { ingested.resolve(); });
    await waitFor(() => expect(feeds).toHaveBeenCalledTimes(1));
    expect(result.current.refresh.isPending).toBe(true);
    expect(result.current.refreshMessage).toBe("Updating Articles…");
    expect(unread).not.toHaveBeenCalled();
    await act(async () => { fetched.resolve(); });
    await waitFor(() => expect(result.current.refreshMessage).toBe("Updating Unread Counts…"));
    expect(result.current.refresh.isPending).toBe(true);
    await act(async () => { counted.resolve(); await Promise.all([first, duplicate]); });
    expect(order).toEqual(["post", "sources", "ingested", "feeds", "counts"]);
    expect(result.current.refreshMessage).toBe("Refresh Complete");
    expect(feeds).toHaveBeenCalledTimes(1);
    expect(feeds.mock.calls[0]?.[0].signal).toBe(sources.mock.calls[0]?.[0].signal);
  });

  it("preserves selection, history, and cached unread counts while replacing authoritative membership", async () => {
    const { result, post, stream, queryClient, did, projection } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    const publicationId = "did:plc:publication";
    const key = ["entries", did, publicationId, "all"];
    const cached = { pages: [{ entries: [], cursor: "tail" }, { entries: [] }], pageParams: [undefined, "tail"] };
    queryClient.setQueryData(key, cached);
    queryClient.setQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did), { ...projection, folders: [{ uri: "old", rkey: "old", value: {} }], unreadCountsByPublicationId: { [publicationId]: 5 }, unreadCountsGeneration: 12, unreadCountsAccuracy: "exact" });
    post.mockResolvedValue(projection);
    await act(async () => { await result.current.refresh.mutateAsync(); });
    expect(result.current.streamSelectedPublicationId).toBeNull();
    expect(queryClient.getQueryData<typeof cached>(key)).toEqual(cached);
    const next = queryClient.getQueryData<projectionClient.PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did));
    expect(next?.folders).toEqual([]);
    expect(next?.unreadCountsByPublicationId).toEqual({ [publicationId]: 5 });
    expect(next?.unreadCountsGeneration).toBe(12);
    expect(stream).toHaveBeenCalledTimes(1);
  });

  it("deduplicates actual fresh article IDs across multiple paints instead of summing counts", async () => {
    const { result, sources, feeds, queryClient, did } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    queryClient.setQueryData(["entries", did, "inactive", "unread"], { pages: [{ entries: [{ entryId: "existing" }] }], pageParams: [undefined] });
    queryClient.setQueryData(["entries", "other-viewer", "inactive", "unread"], { pages: [{ entries: [{ entryId: "new" }] }], pageParams: [undefined] });
    sources.mockImplementation(async ({ onBatch }) => { await onBatch(); await onBatch(); await onBatch(); });
    let pass = 0;
    feeds.mockImplementation(async ({ onNewArticleIds }) => {
      pass++;
      onNewArticleIds?.(pass === 2 ? [] : ["new", "overlap", "existing"]);
      return { newArticleCount: 99 };
    });
    await act(async () => { await result.current.refresh.mutateAsync(); });
    expect(result.current.refreshMessage).toBe("2 New Articles Loaded");
  });

  it("retains only exact server-approved cached Following rows when the server snapshot is cold", async () => {
    const { result, post, sources, projection, queryClient, did } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    const row = (publicationId: string, title = publicationId): projectionClient.SidebarPublicationRow => ({ publicationId, authorDid: publicationId, authorHandle: publicationId, title, discoveredAt: "", appViewScope: { authorDid: publicationId, publicationAtUri: null, publicationScopeAtUris: [], publicationSiteUrls: [] } });
    const keep = row("did:plc:keep"), winner = row("did:plc:winner", "cached"), hidden = row("did:plc:hidden"), removed = row("did:plc:removed"), alias = row("at%3A%2F%2Fdid%3Aplc%3Aalias%2Fsite.standard.publication%2Fkey");
    const freshWinner = { ...winner, title: "Server Wins" }, added = row("did:plc:added");
    queryClient.setQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did), { ...projection, followingTabPublications: [keep, winner, hidden, removed, alias], allPublicationRows: [keep, winner, hidden, removed, alias] });
    post.mockResolvedValue({ ...projection, followingTabPublications: [freshWinner, added], allPublicationRows: [freshWinner, added], retainedFollowingPublicationIds: [keep.publicationId, winner.publicationId, added.publicationId, "at://did:plc:alias/site.standard.publication/key"] });
    const observer = new InfiniteQueryObserver(queryClient, { queryKey: ["aggregateEntries", did, "following", "", "all"], queryFn: async () => ({ entries: [] }), initialPageParam: undefined, getNextPageParam: () => undefined, staleTime: Infinity, initialData: { pages: [{ entries: [] }], pageParams: [undefined] } });
    const stop = observer.subscribe(() => {});
    try {
      await act(async () => { await result.current.refresh.mutateAsync(); });
      const next = queryClient.getQueryData<projectionClient.PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did))!;
      expect(next.followingTabPublications).toEqual([freshWinner, added, keep]);
      expect(next.allPublicationRows).toEqual([freshWinner, added, keep]);
      expect(sources.mock.calls[0]?.[0].rows).toEqual([freshWinner, added, keep]);
    } finally { stop(); }
  });

  it("does not retain cached Following rows when the server supplies no retained IDs", async () => {
    const { result, projection, queryClient, did } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    queryClient.setQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did), { ...projection, followingTabPublications: [{ publicationId: "removed" }] });
    await act(async () => { await result.current.refresh.mutateAsync(); });
    expect(queryClient.getQueryData<projectionClient.PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did))?.followingTabPublications).toEqual([]);
  });

  it("clears an initial bootstrap error after a successful authoritative manual refresh", async () => {
    const { result } = mountProvider({ initialError: true });
    await waitFor(() => expect(result.current.projectionError?.message).toBe("Initial bootstrap failed"));
    await act(async () => { await result.current.refresh.mutateAsync(); });
    expect(result.current.projectionError).toBeNull();
    expect(result.current.refreshMessage).toBe("Refresh Complete");
  });

  it("ignores an older initial stream after the manual POST replaces the sidebar", async () => {
    const gate = deferred();
    const { result, stream, post, projection, queryClient, did } = mountProvider({ initialGate: gate });
    await waitFor(() => expect(stream).toHaveBeenCalledTimes(1));
    post.mockResolvedValue({ ...projection, refreshedAt: "new authoritative sidebar" });
    await act(async () => { await result.current.refresh.mutateAsync(); });
    await act(async () => { gate.resolve(); await gate.promise; });
    expect(queryClient.getQueryData<projectionClient.PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did))?.refreshedAt).toBe("new authoritative sidebar");
    expect(stream).toHaveBeenCalledTimes(1);
  });

  it("settles a stalled POST when its transport ignores cancellation", async () => {
    const { result, post, sources, feeds, rerender } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    const started = deferred();
    post.mockImplementation(async () => { started.resolve(); return new Promise<never>(() => {}); });
    let pending!: Promise<void>;
    act(() => { pending = result.current.refresh.mutateAsync(); });
    const outcome = pending.then(() => "success", () => "cancelled");
    await started.promise;
    spyOn(auth, "useAuth").mockReturnValue({ ...auth.useAuth(), oauthSessionReloadSeq: 1 });
    let settled: string | undefined;
    await act(async () => { rerender(); settled = await outcome; });
    expect(settled).toBe("cancelled");
    expect(sources).not.toHaveBeenCalled(); expect(feeds).not.toHaveBeenCalled();
  });

  for (const failure of ["post", "sources", "feeds", "counts"] as const) {
    it(`never reports success after a ${failure} failure`, async () => {
      const { result, post, sources, feeds, unread } = mountProvider();
      await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
      const error = new Error(`${failure} unavailable`);
      if (failure === "post") post.mockRejectedValue(error);
      if (failure === "sources") sources.mockImplementation(async ({ onBatch }) => { await onBatch(); throw error; });
      if (failure === "feeds") feeds.mockRejectedValue(error);
      if (failure === "counts") unread.mockRejectedValue(error);
      await act(async () => { await expect(result.current.refresh.mutateAsync()).rejects.toThrow(error.message); });
      await waitFor(() => expect(result.current.refresh.isError).toBe(true));
      expect(result.current.refreshMessage).not.toBe("Refresh Complete");
      if (failure === "post") { expect(sources).not.toHaveBeenCalled(); expect(feeds).not.toHaveBeenCalled(); expect(unread).not.toHaveBeenCalled(); }
      if (failure === "sources" || failure === "feeds") expect(unread).toHaveBeenCalledTimes(1);
    });
  }

  it("rejects a POST sidebar for another viewer before applying it", async () => {
    const { result, post, projection, sources } = mountProvider();
    await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
    post.mockResolvedValue({ ...projection, viewerDid: "other" });
    await act(async () => { await expect(result.current.refresh.mutateAsync()).rejects.toThrow("Publication details are unavailable"); });
    expect(sources).not.toHaveBeenCalled();
  });

  for (const phase of ["post", "sources", "feeds", "counts"] as const) {
    it(`aborts on account unmount during ${phase} without subsequent cache work`, async () => {
      const { result, unmount, did, projection, queryClient, stream, post, sources, feeds, unread } = mountProvider();
      await waitFor(() => expect(result.current.bootstrapStreamComplete).toBe(true));
      const pending = deferred();
      let signal: AbortSignal | undefined;
      if (phase === "post") post.mockImplementation(async (_oauth, currentSignal) => { signal = currentSignal; await pending.promise; return projection; });
      if (phase === "sources") sources.mockImplementation(async args => { signal = args.signal; await pending.promise; await args.onBatch(); });
      if (phase === "feeds") feeds.mockImplementation(async args => { signal = args.signal; await pending.promise; return { newArticleCount: 0 }; });
      if (phase === "counts") unread.mockImplementation(async args => { signal = args.signal; await pending.promise; });
      let outcome!: Promise<unknown>;
      act(() => { outcome = result.current.refresh.mutateAsync().catch((error: unknown) => error); });
      await waitFor(() => expect(signal).toBeDefined());
      const snapshot = queryClient.getQueryData<projectionClient.PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did));
      const setQueryData = spyOn(queryClient, "setQueryData");
      unmount(); expect(signal?.aborted).toBe(true);
      pending.resolve();
      const error = await outcome;
      expect(error).toBeInstanceOf(DOMException);
      expect((error as DOMException).name).toBe("AbortError");
      if (phase === "post" || phase === "sources") expect(feeds).not.toHaveBeenCalled();
      if (phase !== "counts") expect(unread).not.toHaveBeenCalled();
      expect(stream).toHaveBeenCalledTimes(1);
      expect(setQueryData).not.toHaveBeenCalled();
      expect(queryClient.getQueryData<projectionClient.PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did))).toBe(snapshot);
    });
  }
});
