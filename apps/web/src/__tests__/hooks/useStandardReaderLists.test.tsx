import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { useStandardReaderLists } from "@/hooks/useStandardReaderLists";
import {
  standardReaderListsQueryKey,
  type StandardReaderList,
  type StandardReaderListsPage,
} from "@/lib/standardReaderListsClient";
const realAuth = { ...(await import("@/hooks/useAuth")) };
const realPDS = { ...(await import("@/hooks/usePDSClient")) };
const realBootstrap = {
  ...(await import("@/contexts/PublicationSidebarContext")),
};
const realLists = { ...(await import("@/lib/standardReaderListsClient")) };
let client: QueryClient;
let oauth: OAuthSession;
let complete: boolean;
let reads: number;
let fail: boolean;
const list: StandardReaderList = {
  uri: "at://did:plc:creator/app.standard-reader.list/tech",
  name: "Tech",
  creatorDid: "did:plc:creator",
  publications: [],
  users: [],
  owned: false,
  saved: true,
};
const page: StandardReaderListsPage = { lists: [list], refreshedAt: "now" };
function wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}
beforeEach(() => {
  reads = 0;
  fail = false;
  complete = false;
  oauth = { did: "did:plc:alice" } as unknown as OAuthSession;
  client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  mock.module("@/hooks/useAuth", () => ({
    ...realAuth,
    useAuth: () => ({
      session: { did: oauth.did },
      oauthSessionReloadSeq: 0,
      getOAuthSession: () => oauth,
    }),
  }));
  mock.module("@/hooks/usePDSClient", () => ({
    ...realPDS,
    usePDSClient: () => ({
      saveStandardReaderList: async () => {
        if (fail) throw new Error("offline");
      },
      removeStandardReaderList: async () => {
        if (fail) throw new Error("offline");
      },
    }),
  }));
  mock.module("@/contexts/PublicationSidebarContext", () => ({
    ...realBootstrap,
    useSidebarBootstrap: () => ({ bootstrapStreamComplete: complete }),
  }));
  mock.module("@/lib/standardReaderListsClient", () => ({
    ...realLists,
    getStandardReaderLists: async () => {
      reads++;
      return page;
    },
    refreshStandardReaderLists: async () => page,
  }));
});
afterEach(() => {
  cleanup();
  client.clear();
  mock.module("@/hooks/useAuth", () => realAuth);
  mock.module("@/hooks/usePDSClient", () => realPDS);
  mock.module("@/contexts/PublicationSidebarContext", () => realBootstrap);
  mock.module("@/lib/standardReaderListsClient", () => realLists);
});
describe("Standard Reader Lists synchronization", () => {
  it("waits for bootstrap and consumes its lists cache without an initial waterfall", async () => {
    const { result, rerender } = renderHook(() => useStandardReaderLists(), {
      wrapper,
    });
    expect(reads).toBe(0);
    act(() => {
      client.setQueryData(standardReaderListsQueryKey(oauth.did), page);
      complete = true;
      rerender();
    });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    expect(reads).toBe(0);
  });
  it("rolls back an unsuccessful direct PDS removal", async () => {
    complete = true;
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    fail = true;
    await act(async () => {
      try {
        await result.current.removeList(list.uri);
      } catch {}
    });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    expect(result.current.error).toBeInstanceOf(Error);
  });
  it("does not install delayed projection refresh for a previous account", async () => {
    complete = true;
    let resolve!: (value: StandardReaderListsPage) => void;
    mock.module("@/lib/standardReaderListsClient", () => ({
      ...realLists,
      getStandardReaderLists: async () => page,
      refreshStandardReaderLists: () =>
        new Promise<StandardReaderListsPage>((done) => {
          resolve = done;
        }),
    }));
    const { result, rerender } = renderHook(() => useStandardReaderLists(), {
      wrapper,
    });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    let pending!: Promise<void>;
    act(() => {
      pending = result.current.refresh();
    });
    await waitFor(() => expect(resolve).toBeDefined());
    oauth = { did: "did:plc:bob" } as unknown as OAuthSession;
    rerender();
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    await act(async () => {
      resolve({
        lists: [{ ...list, name: "Late Alice" }],
        refreshedAt: "later",
      });
      await pending;
    });
    expect(result.current.lists[0]?.name).toBe("Tech");
  });
  it("offers new-grant recovery without leaving an optimistic save behind", async () => {
    complete = true;
    mock.module("@/hooks/usePDSClient", () => ({
      ...realPDS,
      usePDSClient: () => ({
        removeStandardReaderList: async () => {
          throw Object.assign(new Error("insufficient scope"), { status: 403 });
        },
      }),
    }));
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    await act(async () => {
      try {
        await result.current.removeList(list.uri);
      } catch {}
    });
    await waitFor(() => expect(result.current.error).toBeInstanceOf(Error));
    expect((result.current.error as Error).message).toContain(
      "Sign out and sign in again",
    );
    expect(result.current.lists).toHaveLength(1);
  });
  it("restarts cached list continuations after a refreshed membership scope", async () => {
    complete = true;
    const feedKey = ["aggregateEntries", oauth.did, "list", list.uri];
    client.setQueryData(feedKey, {
      pages: [
        { entries: ["old-one"], cursor: "old" },
        { entries: ["old-two"] },
      ],
      pageParams: [undefined, "old"],
    });
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    await act(async () => {
      await result.current.refresh();
    });
    expect(
      (client.getQueryData(feedKey) as { pages: unknown[] }).pages,
    ).toHaveLength(1);
    expect(
      (client.getQueryData(feedKey) as { pageParams: unknown[] }).pageParams,
    ).toEqual([undefined]);
  });
  it("creates an owned public list then reconciles its projection", async () => {
    complete = true;
    const owned = { ...list, uri: "at://did:plc:alice/app.standard-reader.list/created", name: "Reading", owned: true, saved: false };
    const create = mock(async () => ({ uri: owned.uri, cid: "created" }));
    mock.module("@/hooks/usePDSClient", () => ({ ...realPDS, usePDSClient: () => ({ createStandardReaderList: create }) }));
    mock.module("@/lib/standardReaderListsClient", () => ({ ...realLists, getStandardReaderLists: async () => page, refreshStandardReaderLists: async () => ({ ...page, lists: [list, owned] }) }));
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    let created!: StandardReaderList;
    await act(async () => { created = await result.current.createList({ name: "Reading", publications: [], users: [] }); });
    expect(create).toHaveBeenCalledWith({ name: "Reading", publications: [], users: [] });
    expect(created).toMatchObject({ uri: owned.uri, owned: true, saved: false });
    await waitFor(() => expect(result.current.lists).toHaveLength(2));
  });
  it("does not install a delayed created list in a different account", async () => {
    complete = true;
    let resolve!: (value: { uri: string; cid: string }) => void;
    mock.module("@/hooks/usePDSClient", () => ({ ...realPDS, usePDSClient: () => ({ createStandardReaderList: () => new Promise(done => { resolve = done; }) }) }));
    const { result, rerender } = renderHook(() => useStandardReaderLists(), { wrapper });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    let pending!: Promise<StandardReaderList>;
    act(() => { pending = result.current.createList({ name: "Late Alice", publications: [] }); });
    await waitFor(() => expect(resolve).toBeDefined());
    oauth = { did: "did:plc:bob" } as unknown as OAuthSession;
    act(() => rerender());
    await act(async () => {
      resolve({ uri: "at://did:plc:alice/app.standard-reader.list/created", cid: "created" });
      await expect(pending).rejects.toThrow("Your account changed");
    });
    expect(result.current.lists.some(value => value.name === "Late Alice")).toBe(false);
  });
  it("retains committed owned deletion when saved-reference cleanup fails", async () => {
    complete = true;
    const owned = { ...list, uri: "at://did:plc:alice/app.standard-reader.list/owned", owned: true, saved: true };
    const partial = Object.assign(new Error("Your list was deleted, but its saved reference could not be removed."), { originalDeleted: true });
    mock.module("@/hooks/usePDSClient", () => ({ ...realPDS, usePDSClient: () => ({ deleteOwnedStandardReaderList: async () => { throw partial; } }) }));
    mock.module("@/lib/standardReaderListsClient", () => ({ ...realLists, getStandardReaderLists: async () => ({ ...page, lists: [owned] }), refreshStandardReaderLists: async () => ({ ...page, lists: [], complete: false }) }));
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    const resolvedKey = ["standardReaderList", oauth.did, 0, owned.uri];
    client.setQueryData(resolvedKey, owned);
    await act(async () => { await expect(result.current.deleteList(owned.uri)).rejects.toThrow("Your list was deleted"); });
    await waitFor(() => expect(result.current.lists).toEqual([]));
    expect(client.getQueryData(resolvedKey)).toBeUndefined();
    expect(client.getQueryDefaults(["standardReaderDeletedLists", oauth.did, 0]).gcTime).toBe(Infinity);
    expect((result.current.error as Error).message).toContain("Your list was deleted");
  });
  it("rolls back unsuccessful original deletion and rejects deleting another creator", async () => {
    complete = true;
    const owned = { ...list, uri: "at://did:plc:alice/app.standard-reader.list/owned", owned: true };
    const deletion = mock(async () => { throw new Error("offline"); });
    mock.module("@/hooks/usePDSClient", () => ({ ...realPDS, usePDSClient: () => ({ deleteOwnedStandardReaderList: deletion }) }));
    mock.module("@/lib/standardReaderListsClient", () => ({ ...realLists, getStandardReaderLists: async () => ({ ...page, lists: [owned] }) }));
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    await act(async () => { await expect(result.current.deleteList(owned.uri)).rejects.toThrow("offline"); });
    expect(result.current.lists[0]?.uri).toBe(owned.uri);
    await act(async () => { await expect(result.current.deleteList(list.uri)).rejects.toThrow("Only a list created"); });
    expect(deletion).toHaveBeenCalledTimes(1);
  });
  it("offers new-grant recovery for owned creation without inserting a failed draft", async () => {
    complete = true;
    mock.module("@/hooks/usePDSClient", () => ({ ...realPDS, usePDSClient: () => ({ createStandardReaderList: async () => { throw Object.assign(new Error("insufficient scope"), { status: 403 }); } }) }));
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    await act(async () => { await expect(result.current.createList({ name: "Draft", publications: [] })).rejects.toThrow("Sign out and sign in again"); });
    expect(result.current.lists).toEqual([list]);
  });
  it("resolves creators with no public lists using only the server identity", async () => {
    mock.module("@/lib/standardReaderListsClient", () => ({ ...realLists, searchStandardReaderLists: async () => ({ lists: [], refreshedAt: "now", creatorDid: "did:plc:resolved" }) }));
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await expect(result.current.resolveCreator("reader.test")).resolves.toEqual({ did: "did:plc:resolved", handle: "reader.test" });
  });
  it("rejects missing creator identities instead of deriving a DID from typed text", async () => {
    mock.module("@/lib/standardReaderListsClient", () => ({ ...realLists, searchStandardReaderLists: async () => ({ lists: [], refreshedAt: "now" }) }));
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await expect(result.current.resolveCreator("reader.test")).rejects.toThrow("creator could not be resolved");
  });
  it("preserves cached rows and exposes a retryable warning for an incomplete refresh", async () => {
    complete = true;
    mock.module("@/lib/standardReaderListsClient", () => ({
      ...realLists,
      getStandardReaderLists: async () => page,
      refreshStandardReaderLists: async () => ({
        lists: [],
        refreshedAt: "later",
        complete: false,
      }),
    }));
    const { result } = renderHook(() => useStandardReaderLists(), { wrapper });
    await waitFor(() => expect(result.current.lists).toHaveLength(1));
    await act(async () => {
      await result.current.refresh();
    });
    await waitFor(() =>
      expect(result.current.query.data?.complete).toBe(false),
    );
    expect(result.current.lists[0]?.uri).toBe(list.uri);
    expect((result.current.error as Error).message).toContain(
      "Some lists could not be refreshed",
    );
    expect((result.current.error as Error).message).toContain("Try Refresh");
  });
});
