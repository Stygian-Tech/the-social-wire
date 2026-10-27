/**
 * Tests for useEntries and useEntry hooks (Thin AppView gateway path).
 */

import { describe, it, expect, mock, spyOn, beforeEach, afterEach } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { onlineManager, QueryClient, QueryClientProvider, useQuery, type InfiniteData } from "@tanstack/react-query";
import React from "react";
import { useEntries, useEntry, useAggregateFeedEntries, type EntriesPage } from "@/hooks/useEntries";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/hooks/usePublicationSidebarData";
import {
  MOCK_ENTRIES,
  MOCK_ENTRY_DETAIL,
} from "../mocks/handlers/service";
import { dummyPublicationSidebarProjection } from "@/lib/dummyReaderData";
import { PDS_SESSION_ATTESTATION_RECEIPT_HEADER } from "@/lib/pdsSessionAttestation";

import { advanceFeedRefreshRevision, invalidateReadFeedRefreshes, recordReadEntryMutations } from "@/lib/feedRefreshCoordinator";

const ORIG_ENV = { ...process.env };
const ORIG_FETCH = globalThis.fetch;

const mockFetchHandler = mock(async (url: string) => {
  if (url.includes("/xrpc/app.thesocialwire.appview.listEntries")) {
    expect(new URL(url).searchParams.get("authorDid")).toBe("did:plc:testuser");
    expect(new URL(url).searchParams.get("limit")).toBe("1");
    return new Response("{}", { headers: { [PDS_SESSION_ATTESTATION_RECEIPT_HEADER]: "viewer-receipt" } });
  }
  if (url.includes("/xrpc/app.thesocialwire.appview.getFeed")) {
    return new Response(
      JSON.stringify({ entries: MOCK_ENTRIES, cursor: undefined }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }
  if (url.includes("/xrpc/app.thesocialwire.appview.enrollSources")) {
    return new Response(JSON.stringify({ indexed: 0 }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }
  if (url.includes("/xrpc/app.thesocialwire.appview.getEntry")) {
    return new Response(
      JSON.stringify(MOCK_ENTRY_DETAIL),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }
  if (url.includes("/v1/telemetry/client-performance")) {
    return new Response(null, { status: 202 });
  }
  return new Response("not found", { status: 404 });
});

const pdsNonces = new Map<string, string>();
let pdsNonceIndex = 0;
const mockOAuthSession = {
  did: "did:plc:testuser",
  getTokenSet: async () => ({
    access_token: "access-token",
    token_type: "DPoP",
  }),
  getTokenInfo: async () => ({ aud: "https://pds.example" }),
  fetchHandler: async () => {
    const nonce = `pds-nonce-${++pdsNonceIndex}`;
    pdsNonces.set("https://pds.example", nonce);
    return new Response(JSON.stringify({ records: [] }), {
      headers: { "DPoP-Nonce": nonce },
    });
  },
  server: {
    dpopKey: {
      bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
      algorithms: ["ES256"],
      createJwt: async () => "dpop-proof",
    },
    dpopNonces: {
      get: async (origin: string) => pdsNonces.get(origin),
      set: async (origin: string, nonce: string) => {
        pdsNonces.set(origin, nonce);
      },
    },
    serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
  },
} as never;

let activeOAuthSession = mockOAuthSession;
let activeViewerDid = "did:plc:testuser";
let activeReloadSeq = 0;
const getOAuthSession = () => activeOAuthSession;

mock.module("@/hooks/useAuth", () => ({
  useAuth: () => ({
    session: { did: activeViewerDid },
    isLoading: false,
    oauthSessionReloadSeq: activeReloadSeq,
    applyOAuthSession: () => {},
    getOAuthSession,
    getAuthFetch: () => null,
    reconcileOAuthSession: async () => false,
    signIn: async () => {},
    signOut: async () => {},
  }),
}));

function makeWrapper() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  qc.setQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("did:plc:testuser"), {
    viewerDid: "did:plc:testuser",
    folders: [],
    publicationPrefs: [],
    allPublicationRows: [
      {
        publicationId: "did:plc:alice",
        authorDid: "did:plc:alice",
        authorHandle: "alice",
        title: "Alice",
        discoveredAt: "2026-01-01T00:00:00.000Z",
        appViewScope: {
          authorDid: "did:plc:alice",
          publicationAtUri: null,
          publicationScopeAtUris: [],
          publicationSiteUrls: [],
        },
      },
    ],
    myPublications: [],
    subscribedUnfoldered: [],
    followingTabPublications: [],
    enrollAuthorDids: [],
    refreshedAt: "2026-01-01T00:00:00.000Z",
  });

  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  };
}

describe("useEntries", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_USE_THIN_APPVIEW = "true";
    mockFetchHandler.mockClear();
    globalThis.fetch = mockFetchHandler as unknown as typeof fetch;
    pdsNonces.clear();
    pdsNonceIndex = 0;
  });

  afterEach(() => {
    process.env = { ...ORIG_ENV };
    globalThis.fetch = ORIG_FETCH;
  });

  it("fetches entries from AppView for a publication", async () => {
    const { result } = renderHook(() => useEntries("did:plc:alice"), {
      wrapper: makeWrapper(),
    });

    await waitFor(() => expect(result.current.isLoading).toBe(false));

    const entries = result.current.data?.pages.flatMap((p) => p.entries) ?? [];
    expect(entries).toHaveLength(MOCK_ENTRIES.length);
    expect(entries[0].title).toBe("First Post");
    expect(mockFetchHandler).toHaveBeenCalled();
  });

  it("requests an authoritative unread page from AppView", async () => {
    const { result } = renderHook(
      () => useEntries("did:plc:alice", "unread"),
      { wrapper: makeWrapper() }
    );

    await waitFor(() => expect(result.current.isLoading).toBe(false));
    await waitFor(() =>
      expect(
        mockFetchHandler.mock.calls.some(([url]) => {
          const requestUrl = new URL(String(url));
          return (
            requestUrl.pathname === "/xrpc/app.thesocialwire.appview.getFeed" &&
            requestUrl.searchParams.get("filter") === "unread"
          );
        })
      ).toBe(true)
    );
    expect(
      mockFetchHandler.mock.calls.filter(([url]) => {
        const requestUrl = new URL(String(url));
        return (
          requestUrl.pathname === "/xrpc/app.thesocialwire.appview.getFeed" &&
          requestUrl.searchParams.get("filter") === "unread"
        );
      })
    ).toHaveLength(1);
  });

  it("uses dummy entries without an AppView request in local", async () => {
    process.env.NEXT_PUBLIC_APP_ENV = "local";
    delete process.env.NEXT_PUBLIC_USE_DUMMY_DATA;
    const publication =
      dummyPublicationSidebarProjection.subscribedUnfoldered[0];
    expect(publication).toBeDefined();

    const { result } = renderHook(
      () => useEntries(publication!.publicationId),
      { wrapper: makeWrapper() },
    );

    await waitFor(() => expect(result.current.isLoading).toBe(false));

    const entries = result.current.data?.pages.flatMap((page) => page.entries);
    expect(entries?.length).toBeGreaterThan(0);
    expect(mockFetchHandler.mock.calls.map(([url]) => url)).toEqual([]);
  });

  it("keeps fresh cached rows visible without redundant refresh or enroll on remount", async () => {
    const qc = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    });
    qc.setQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("did:plc:testuser"), {
      viewerDid: "did:plc:testuser",
      folders: [],
      publicationPrefs: [],
      allPublicationRows: [
        {
          publicationId: "did:plc:alice",
          authorDid: "did:plc:alice",
          authorHandle: "alice",
          title: "Alice",
          discoveredAt: "2026-01-01T00:00:00.000Z",
          appViewScope: {
            authorDid: "did:plc:alice",
            publicationAtUri: null,
            publicationScopeAtUris: [],
            publicationSiteUrls: [],
          },
        },
      ],
      myPublications: [],
      subscribedUnfoldered: [],
      followingTabPublications: [],
      enrollAuthorDids: [],
      refreshedAt: "2026-01-01T00:00:00.000Z",
    });
    qc.setQueryData(
      ["entries", "did:plc:testuser", "did:plc:alice", "all"],
      {
      pages: [{ entries: MOCK_ENTRIES, cursor: undefined }],
      pageParams: [undefined],
      }
    );

    function Wrapper({ children }: { children: React.ReactNode }) {
      return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
    }

    const { unmount } = renderHook(() => useEntries("did:plc:alice"), {
      wrapper: Wrapper,
    });
    unmount();
    renderHook(() => useEntries("did:plc:alice"), { wrapper: Wrapper });

    expect(
      qc.getQueryData([
        "entries",
        "did:plc:testuser",
        "did:plc:alice",
        "all",
      ])
    ).toBeDefined();
    await act(async () => { await new Promise(resolve => setTimeout(resolve, 30)); });
    expect(mockFetchHandler.mock.calls.filter(([url]) => /getFeed|enrollSources/.test(String(url)))).toHaveLength(0);
  });

  it("returns empty pages when publicationKey is null", async () => {
    const { result } = renderHook(() => useEntries(null), {
      wrapper: makeWrapper(),
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.data).toBeUndefined();
  });
});

describe("useEntry", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_USE_THIN_APPVIEW = "true";
    mockFetchHandler.mockClear();
    globalThis.fetch = mockFetchHandler as unknown as typeof fetch;
    pdsNonces.clear();
    pdsNonceIndex = 0;
  });

  afterEach(() => {
    process.env = { ...ORIG_ENV };
    globalThis.fetch = ORIG_FETCH;
  });

  it("fetches entry detail from AppView by AT-URI", async () => {
    const { result } = renderHook(
      () => useEntry("at://did:plc:alice/site.standard.document/entry1"),
      { wrapper: makeWrapper() }
    );

    await waitFor(() => expect(result.current.isLoading).toBe(false));

    expect(result.current.data?.title).toBe(MOCK_ENTRY_DETAIL.title);
    expect(result.current.data?.contentHtml).toBe(MOCK_ENTRY_DETAIL.contentHtml);
    expect(mockFetchHandler).toHaveBeenCalled();
  });

  it("returns null data when entryId is null", async () => {
    const { result } = renderHook(() => useEntry(null), {
      wrapper: makeWrapper(),
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.data).toBeUndefined();
  });

  it("refreshes the Subscribed head when returning to the visible tab", async () => {
    const descriptor = Object.getOwnPropertyDescriptor(document, "visibilityState");
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const { result, unmount } = renderHook(() => useAggregateFeedEntries({ kind: "subscribed" }), {
      wrapper: ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>,
    });
    try {
      await waitFor(() => expect(result.current.isSuccess).toBe(true));
      const requests = () => mockFetchHandler.mock.calls.filter(([url]) => url.includes("app.thesocialwire.appview.getFeed"));
      const previous = requests().length;
      act(() => window.dispatchEvent(new window.Event("focus")));
      await waitFor(() => expect(requests().length).toBe(previous + 1));
      expect(result.current.data?.pages).toHaveLength(1);
    } finally {
      unmount(); client.clear();
      if (descriptor) Object.defineProperty(document, "visibilityState", descriptor);
      else Reflect.deleteProperty(document, "visibilityState");
    }
  });
  it("refreshes only the resolved list metadata after its prepared first page", async () => {
    const client = new QueryClient({defaultOptions: {queries: {retry: false}}});
    const invalidate = mock(client.invalidateQueries.bind(client));
    client.invalidateQueries = invalidate;
    const uri = "at://did:plc:alice/app.standard-reader.list/list";
    const {result} = renderHook(() => useAggregateFeedEntries({kind: "list", id: uri}), {
      wrapper: ({children}: {children: React.ReactNode}) => <QueryClientProvider client={client}>{children}</QueryClientProvider>,
    });
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(invalidate).toHaveBeenCalledWith({queryKey: ["standardReaderList", "did:plc:testuser", 0, uri], exact: true});
    expect(invalidate).toHaveBeenCalledTimes(1);
    client.clear();
  });

  it("replaces an initial list resolution still in flight after metadata preparation", async () => {
    const client = new QueryClient({defaultOptions: {queries: {retry: false}}});
    const uri = "at://did:plc:alice/app.standard-reader.list/slow";
    let finishOldResolution: ((value: {publicationDetails: string[]}) => void) | undefined;
    const oldResolution = new Promise<{publicationDetails: string[]}>(resolve => {finishOldResolution = resolve;});
    let resolutionRequests = 0;
    const resolveList = mock(() => ++resolutionRequests === 1 ? oldResolution : Promise.resolve({publicationDetails: ["Prepared Publication"]}));
    const {result, unmount} = renderHook(() => {
      const list = useQuery({queryKey: ["standardReaderList", "did:plc:testuser", 0, uri], queryFn: resolveList, staleTime: 60000});
      const feed = useAggregateFeedEntries({kind: "list", id: uri});
      return {list, feed};
    }, {
      wrapper: ({children}: {children: React.ReactNode}) => <QueryClientProvider client={client}>{children}</QueryClientProvider>,
    });
    await waitFor(() => expect(result.current.list.data?.publicationDetails).toEqual(["Prepared Publication"]));
    expect(resolveList).toHaveBeenCalledTimes(2);
    finishOldResolution?.({publicationDetails: []});
    await oldResolution;
    expect(result.current.list.data?.publicationDetails).toEqual(["Prepared Publication"]);
    unmount();
    client.clear();
  });

});


describe("reader lifecycle refreshes", () => {
  const viewer = "did:plc:testuser";
  const publication = "did:plc:alice";
  type Scope = "publication" | "subscribed" | "following";
  type Filter = "all" | "unread";
  let client: QueryClient;
  let requests: (string | null)[];
  let respond: (signal?: AbortSignal | null) => Promise<Response>;
  const row = (id: string) => ({ ...MOCK_ENTRIES[0], entryId: id, title: id, isRead: false });
  const json = (entries: EntriesPage["entries"], cursor?: string) =>
    new Response(JSON.stringify({ entries, cursor }), { headers: { "Content-Type": "application/json" } });
  const keyFor = (scope: Scope, filter: Filter = "all", did = viewer) => scope === "publication"
    ? ["entries", did, publication, filter]
    : ["aggregateEntries", did, scope, "", filter];
  const seed = (scope: Scope, filter: Filter = "all", did = viewer) => {
    const data = {
      pages: [{ entries: [row("cached-head")], cursor: "page-two" }, { entries: [row("cached-tail")], cursor: "page-three" }],
      pageParams: [undefined, "page-two"],
    };
    client.setQueryData(keyFor(scope, filter, did), data, { updatedAt: Date.now() - 60_000 });
    return data;
  };
  function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
  }
  function useFeed(scope: Scope, filter: Filter = "all") {
    // Each test keeps the hook kind fixed; props only change the filter/account.
    const publicationFeed = useEntries(scope === "publication" ? publication : null, filter);
    const aggregateFeed = useAggregateFeedEntries(scope === "publication" ? null : { kind: scope }, filter);
    return scope === "publication" ? publicationFeed : aggregateFeed;
  }
  const ids = (data: InfiniteData<EntriesPage> | undefined) => data?.pages.flatMap(page => page.entries.map(entry => entry.entryId));
  const settle = async () => { await act(async () => { await new Promise(resolve => setTimeout(resolve, 25)); }); };
  const reconnect = async () => {
    await act(async () => { onlineManager.setOnline(false); });
    await act(async () => { onlineManager.setOnline(true); });
  };

  beforeEach(() => {
    process.env.NEXT_PUBLIC_APP_ENV = "production";
    process.env.NEXT_PUBLIC_USE_DUMMY_DATA = "false";
    process.env.NEXT_PUBLIC_USE_THIN_APPVIEW = "true";
    activeViewerDid = viewer;
    activeOAuthSession = mockOAuthSession;
    activeReloadSeq = 0;
    client = new QueryClient({ defaultOptions: { queries: { retry: false, retryDelay: 1 } } });
    requests = [];
    respond = async () => json([]);
    onlineManager.setOnline(true);
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
      if (url.pathname.endsWith("/app.thesocialwire.appview.getFeed")) {
        requests.push(url.searchParams.get("cursor"));
        return respond(init?.signal ?? (input instanceof Request ? input.signal : undefined));
      }
      if (url.pathname.endsWith("/app.thesocialwire.appview.listEntries")) {
        return new Response("{}", { headers: { [PDS_SESSION_ATTESTATION_RECEIPT_HEADER]: "viewer-receipt" } });
      }
      return new Response("{}", { headers: { "Content-Type": "application/json" } });
    }) as typeof fetch;
  });
  afterEach(() => {
    cleanup();
    client.clear();
    onlineManager.setOnline(true);
    activeViewerDid = viewer;
    activeOAuthSession = mockOAuthSession;
    process.env = { ...ORIG_ENV };
    globalThis.fetch = ORIG_FETCH;
  });

  for (const supersede of ["read", "account", "generation", "unmount"] as const) {
    it(`visible aggregate refresh preserves Production guards after ${supersede}`, async () => {
      const scope = "subscribed";
      const descriptor = Object.getOwnPropertyDescriptor(document, "visibilityState");
      Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
      seed(scope);
      client.setQueryData(keyFor(scope), client.getQueryData(keyFor(scope)));
      let finish!: (response: Response) => void;
      respond = () => new Promise(resolve => { finish = resolve; });
      const hook = renderHook(() => useFeed(scope), { wrapper: Wrapper });
      try {
        await settle();
        expect(requests).toEqual([]);
        act(() => { window.dispatchEvent(new window.Event("focus")); });
        await waitFor(() => expect(requests).toHaveLength(1));
        if (supersede === "read") {
          recordReadEntryMutations(client, activeOAuthSession, ["cached-head"]);
          client.setQueryData<InfiniteData<EntriesPage>>(keyFor(scope), current => ({ ...current!, pages: current!.pages.map(page => ({ ...page, entries: page.entries.map(entry => ({ ...entry, isRead: true })) })) }));
        } else if (supersede === "account") {
          activeOAuthSession = Object.assign({}, mockOAuthSession) as never;
          activeReloadSeq++;
        } else if (supersede === "generation") {
          advanceFeedRefreshRevision(client, keyFor(scope));
        } else hook.unmount();
        const updatedAt = client.getQueryState(keyFor(scope))?.dataUpdatedAt;
        await act(async () => { finish(json([row("late-visible")])); });
        await settle();
        expect(ids(client.getQueryData(keyFor(scope)))).toEqual(["cached-head", "cached-tail"]);
        expect(client.getQueryState(keyFor(scope))?.dataUpdatedAt).toBe(updatedAt);
        if (supersede === "read") expect(client.getQueryData<InfiniteData<EntriesPage>>(keyFor(scope))?.pages[0].entries[0].isRead).toBe(true);
      } finally {
        hook.unmount();
        if (descriptor) Object.defineProperty(document, "visibilityState", descriptor);
        else Reflect.deleteProperty(document, "visibilityState");
      }
    });
  }

  for (const transition of ["filter", "disable", "unmount"] as const) {
    it(`does not restart a cold replacement after ${transition} during cancellation`, async () => {
      const finishes: ((value: Response) => void)[] = [];
      respond = () => new Promise(resolve => { finishes.push(resolve); });
      const hook = renderHook(({ filter, enabled }: { filter: Filter; enabled: boolean }) =>
        useEntries(enabled ? publication : null, filter), {
        wrapper: Wrapper, initialProps: { filter: "all" as Filter, enabled: true },
      });
      await waitFor(() => expect(requests).toHaveLength(1));
      const originalCancel = client.cancelQueries.bind(client);
      let resume!: () => void;
      const cancelled = new Promise<void>(resolve => { resume = resolve; });
      const cancel = spyOn(client, "cancelQueries").mockImplementation(async (...args) => {
        await originalCancel(...args);
        await cancelled;
      });
      try {
        activeOAuthSession = Object.assign({}, mockOAuthSession) as never;
        activeReloadSeq++;
        hook.rerender({ filter: "all", enabled: true });
        await waitFor(() => expect(cancel).toHaveBeenCalledTimes(1));
        if (transition === "unmount") hook.unmount();
        else hook.rerender({ filter: transition === "filter" ? "unread" : "all", enabled: transition !== "disable" });
        if (transition === "filter") await waitFor(() => expect(requests).toHaveLength(2));
        const countBeforeResume = requests.length;
        await act(async () => { resume(); });
        await settle();
        expect(requests).toHaveLength(countBeforeResume);
        await act(async () => { finishes.forEach(finish => finish(json([row("late")]))); });
        await settle();
        expect(client.getQueryData(keyFor("publication"))).toBeUndefined();
        if (transition !== "unmount") hook.unmount();
      } finally {
        resume();
        cancel.mockRestore();
      }
    });
  }

  for (const scope of ["publication", "subscribed", "following"] as const) {
    for (const trigger of ["remount", "reconnect"] as const) {
      for (const response of ["empty", "short", "throw"] as const) {
        it(`${scope} ${trigger} keeps two cached pages after ${response} refresh and permits retry`, async () => {
          seed(scope);
          // Mount fresh once, then make it stale to test a real remount/reconnect.
          client.setQueryData(keyFor(scope), client.getQueryData(keyFor(scope)));
          let hook = renderHook(() => useFeed(scope), { wrapper: Wrapper });
          await settle();
          expect(requests).toEqual([]);
          client.setQueryData(keyFor(scope), client.getQueryData(keyFor(scope)), { updatedAt: Date.now() - 60_000 });
          respond = async () => {
            if (response === "throw") throw new Error("network unavailable");
            return json(response === "empty" ? [] : [row("new-head")]);
          };
          if (trigger === "remount") {
            hook.unmount();
            hook = renderHook(() => useFeed(scope), { wrapper: Wrapper });
          } else await reconnect();
          await waitFor(() => expect(requests).toHaveLength(1));
          await waitFor(() => expect(hook.result.current.isFetching).toBe(false));
          expect(ids(hook.result.current.data)).toEqual(response === "short" ? ["new-head", "cached-head", "cached-tail"] : ["cached-head", "cached-tail"]);
          expect(hook.result.current.data?.pageParams).toEqual([undefined, "page-two"]);
          expect(hook.result.current.isError).toBe(response === "throw");
          await settle();
          expect(requests).toEqual([null]);
          if (response === "throw") {
            respond = async () => json([row("recovered")]);
            await act(async () => { await hook.result.current.refetch(); });
            await waitFor(() => expect(hook.result.current.isError).toBe(false));
            expect(ids(hook.result.current.data)).toEqual(["recovered", "cached-head", "cached-tail"]);
          }
          hook.unmount();
        });
      }
    }

    for (const settlement of ["before", "after"] as const) {
      it(`${scope} remount starts fresh before aborted fetch settles ${settlement} replacement resolution`, async () => {
        seed(scope);
        let oldSignal: AbortSignal | null | undefined;
        let newSignal: AbortSignal | null | undefined;
        let failOld!: (error: Error) => void;
        let finishNew!: (response: Response) => void;
        respond = signal => {
          if (requests.length === 1) {
            oldSignal = signal;
            return new Promise((_resolve, reject) => { failOld = reject; });
          }
          newSignal = signal;
          return new Promise(resolve => { finishNew = resolve; });
        };
        const first = renderHook(() => useFeed(scope), { wrapper: Wrapper });
        await waitFor(() => expect(requests).toHaveLength(1));
        expect(oldSignal?.aborted).toBe(false);
        first.unmount();
        expect(oldSignal?.aborted).toBe(true);
        // Leave the transport abort rejection pending until a new observer has
        // mounted and begun a separate request.
        const second = renderHook(() => useFeed(scope), { wrapper: Wrapper });
        await waitFor(() => expect(requests).toHaveLength(2));
        expect(newSignal).not.toBe(oldSignal);
        expect(newSignal?.aborted).toBe(false);
        expect(ids(second.result.current.data)).toEqual(["cached-head", "cached-tail"]);
        if (settlement === "before") {
          await act(async () => { failOld(new DOMException("aborted", "AbortError")); });
          await settle();
          expect(second.result.current.isFetching).toBe(true);
        }
        await act(async () => { finishNew(json([row("fresh-remount")])); });
        await waitFor(() => expect(ids(second.result.current.data)).toEqual(["fresh-remount", "cached-head", "cached-tail"]));
        if (settlement === "after") {
          await act(async () => { failOld(new DOMException("aborted", "AbortError")); });
        }
        await settle();
        expect(second.result.current.isError).toBe(false);
        expect(second.result.current.isFetching).toBe(false);
        expect(newSignal?.aborted).toBe(false);
        expect(requests).toEqual([null, null]);
        expect(second.result.current.data?.pageParams).toEqual([undefined, "page-two"]);
        second.unmount();
      });
    }

    it(`${scope} keeps Unread authoritative on stale mount`, async () => {
      seed(scope, "unread");
      const { result, unmount } = renderHook(() => useFeed(scope, "unread"), { wrapper: Wrapper });
      await waitFor(() => expect(result.current.data?.pages).toHaveLength(1));
      expect(ids(result.current.data)).toEqual([]);
      expect(requests).toEqual([null]);
      unmount();
    });

    for (const supersede of ["read", "account", "generation", "cancel"] as const) {
      it(`${scope} rejects a late mount refresh after ${supersede}`, async () => {
        seed(scope);
        let finish!: (response: Response) => void;
        respond = () => new Promise(resolve => { finish = resolve; });
        const { result, rerender, unmount } = renderHook(() => useFeed(scope), { wrapper: Wrapper });
        await waitFor(() => expect(requests).toHaveLength(1));
        if (supersede === "read") {
          recordReadEntryMutations(client, activeOAuthSession, ["cached-head"]);
          client.setQueryData<InfiniteData<EntriesPage>>(keyFor(scope), current => ({ ...current!, pages: current!.pages.map(page => ({ ...page, entries: page.entries.map(entry => ({ ...entry, isRead: true })) })) }));
        } else if (supersede === "account") {
          activeViewerDid = "did:plc:other";
          activeOAuthSession = { did: activeViewerDid } as never;
          seed(scope, "all", activeViewerDid);
          // Keep the new account's baseline fresh so only the old request resolves.
          client.setQueryData(keyFor(scope, "all", activeViewerDid), client.getQueryData(keyFor(scope, "all", activeViewerDid)));
          rerender();
        } else if (supersede === "generation") {
          advanceFeedRefreshRevision(client, keyFor(scope));
        } else await act(async () => { await client.cancelQueries({ queryKey: keyFor(scope), exact: true }); });
        const updatedAt = client.getQueryState(keyFor(scope))?.dataUpdatedAt;
        await act(async () => { finish(json([row("late-stale")])); });
        await settle();
        expect(ids(result.current.data)).toEqual(["cached-head", "cached-tail"]);
        expect(ids(client.getQueryData(keyFor(scope)))).toEqual(["cached-head", "cached-tail"]);
        expect(client.getQueryState(keyFor(scope))?.dataUpdatedAt).toBe(updatedAt);
        if (supersede === "read") expect(result.current.data?.pages[0].entries[0].isRead).toBe(true);
        unmount();
      });
    }

    for (const filter of ["all", "unread"] as const) {
      for (const oldOutcome of ["resolve", "reject"] as const) {
        for (const cached of [true, false]) {
          it(`${scope} replaces ${cached ? "cached" : "cold"} same-DID session work and ignores late old ${oldOutcome} (${filter})`, async () => {
            if (cached) seed(scope, filter);
            let finishOld!: (value: Response) => void, failOld!: (reason: Error) => void;
            let finishNew!: (value: Response) => void;
            let oldSignal: AbortSignal | null | undefined, newSignal: AbortSignal | null | undefined;
            respond = signal => {
              if (requests.length === 1) {
                oldSignal = signal;
                return new Promise((resolve, reject) => { finishOld = resolve; failOld = reject; });
              }
              newSignal = signal;
              return new Promise(resolve => { finishNew = resolve; });
            };
            const hook = renderHook(() => useFeed(scope, filter), { wrapper: Wrapper });
            await waitFor(() => expect(requests).toHaveLength(1));
            activeOAuthSession = Object.assign({}, mockOAuthSession) as never;
            activeReloadSeq++;
            hook.rerender();
            await waitFor(() => expect(requests).toHaveLength(2));
            expect(oldSignal?.aborted).toBe(true);
            expect(newSignal?.aborted).toBe(false);
            expect(ids(hook.result.current.data)).toEqual(cached ? ["cached-head", "cached-tail"] : undefined);
            expect(Boolean(hook.result.current.isPending)).toBe(!cached);
            await act(async () => {
              if (oldOutcome === "resolve") finishOld(json([row("old-session")]));
              else failOld(new Error("old session failed"));
            });
            await settle();
            expect(hook.result.current.isFetching).toBe(true);
            expect(hook.result.current.isError).toBe(false);
            expect(newSignal?.aborted).toBe(false);
            await act(async () => { finishNew(json([row("new-session")])); });
            const expected = cached && filter === "all" ? ["new-session", "cached-head", "cached-tail"] : ["new-session"];
            await waitFor(() => expect(ids(hook.result.current.data)).toEqual(expected));
            expect(hook.result.current.isFetching).toBe(false);
            expect(hook.result.current.isError).toBe(false);
            expect(client.getQueryState(keyFor(scope, filter))?.isInvalidated).toBe(false);
            expect(hook.result.current.data?.pageParams).toEqual(cached && filter === "all" ? [undefined, "page-two"] : [undefined]);
            expect(hook.result.current.isPending).toBe(false);
            expect(requests).toEqual([null, null]);
            hook.unmount();
          });
        }
      }
    }

    for (const supersede of ["read", "generation"] as const) {
      it(`${scope} rejects a cold replacement response superseded by ${supersede}`, async () => {
        const finishes: ((value: Response) => void)[] = [];
        respond = () => new Promise(resolve => { finishes.push(resolve); });
        const hook = renderHook(() => useFeed(scope, "unread"), { wrapper: Wrapper });
        await waitFor(() => expect(requests).toHaveLength(1));
        activeOAuthSession = Object.assign({}, mockOAuthSession) as never;
        activeReloadSeq++;
        hook.rerender();
        await waitFor(() => expect(requests).toHaveLength(2));
        if (supersede === "read") invalidateReadFeedRefreshes(client, activeOAuthSession);
        else advanceFeedRefreshRevision(client, keyFor(scope, "unread"));
        await act(async () => { finishes[1](json([row("superseded-replacement")])); });
        await waitFor(() => expect(hook.result.current.isFetching).toBe(false));
        await act(async () => { finishes[0](json([row("old-session")])); });
        await settle();
        expect(client.getQueryData(keyFor(scope, "unread"))).toBeUndefined();
        expect(client.getQueryState(keyFor(scope, "unread"))?.dataUpdatedAt).toBe(0);
        expect(requests).toEqual([null, null]);
        hook.unmount();
      });
    }

    it(`${scope} preserves initial fetching and cursor pagination`, async () => {
      respond = async () => json([row(requests.length === 1 ? "initial" : "next")], requests.length === 1 ? "next-page" : undefined);
      const { result, unmount } = renderHook(() => useFeed(scope), { wrapper: Wrapper });
      await waitFor(() => expect(ids(result.current.data)).toEqual(["initial"]));
      await act(async () => { await result.current.fetchNextPage(); });
      await waitFor(() => expect(ids(result.current.data)).toEqual(["initial", "next"]));
      expect(requests).toEqual([null, "next-page"]);
      unmount();
    });
  }
});
