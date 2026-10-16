import { afterEach, expect, it, spyOn } from "bun:test";
import { createElement, type ReactNode } from "react";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Bootstrap from "@/lib/bootstrapStreamClient";
import * as Projection from "@/lib/publicationProjectionClient";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import { ENTRIES_QUERY_KEY } from "@/hooks/useEntries";
import { MANUAL_SIDEBAR_REFRESH_TIMEOUT_MS, PublicationSidebarProvider, useSidebarBootstrap } from "@/contexts/PublicationSidebarContext";

const restores: (() => void)[] = [];
const clients: QueryClient[] = [];
afterEach(() => { cleanup(); restores.splice(0).forEach(restore => restore()); clients.splice(0).forEach(client => client.clear()); });

function aborted(signal: AbortSignal): Promise<never> {
  return new Promise((_resolve, reject) => {
    if (signal.aborted) reject(signal.reason);
    else signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
}
function fixture() {
  const viewer = `did:plc:refresh-${crypto.randomUUID()}`;
  let activeViewer = viewer;
  let oauth = { did: viewer } as OAuthSession;
  let reload = 0;
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({
    session: { did: activeViewer }, getOAuthSession: () => oauth, oauthSessionReloadSeq: reload,
  }) as ReturnType<typeof Auth.useAuth>);
  restores.push(() => auth.mockRestore());
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  clients.push(client);
  const projection: Projection.PublicationSidebarProjection = {
    viewerDid: viewer, folders: [], publicationPrefs: [], allPublicationRows: [], myPublications: [],
    subscribedUnfoldered: [], followingTabPublications: [], enrollAuthorDids: [], refreshedAt: "2026-10-16T00:00:00Z",
  };
  const sidebarKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewer);
  const entriesKey = [...ENTRIES_QUERY_KEY(viewer, "publication"), "all"];
  const rows = { pages: [{ entries: [{ entryId: "cached", title: "Cached story" }] }], pageParams: [undefined] };
  client.setQueryData(sidebarKey, projection);
  client.setQueryData(entriesKey, rows);
  let expire: (() => void) | undefined;
  const realTimeout = globalThis.setTimeout;
  globalThis.setTimeout = ((callback: () => void, ms?: number, ...args: unknown[]) => {
    if (ms === MANUAL_SIDEBAR_REFRESH_TIMEOUT_MS) { expire = callback; return 987654; }
    return realTimeout(callback, ms, ...args);
  }) as typeof setTimeout;
  restores.push(() => { globalThis.setTimeout = realTimeout; });
  const hook = renderHook(useSidebarBootstrap, { wrapper: ({ children }: { children: ReactNode }) =>
    createElement(QueryClientProvider, { client }, createElement(PublicationSidebarProvider, null, children)) });
  return { ...hook, client, projection, sidebarKey, entriesKey, rows,
    expire: () => { if (!expire) throw new Error("No refresh deadline"); expire(); },
    renew: () => { oauth = { did: viewer } as OAuthSession; reload++; hook.rerender(); },
    switchAccount: () => { activeViewer = `${viewer}-other`; oauth = { did: activeViewer } as OAuthSession; hook.rerender(); } };
}

it("bounds the whole manual POST and stream, restores retry, and preserves cached stories", async () => {
  let calls = 0;
  let streamSignal: AbortSignal | undefined;
  let postSignal: AbortSignal | undefined;
  const stream = spyOn(Bootstrap, "consumeBootstrapStream").mockImplementation(async args => {
    calls++;
    if (calls === 1) return;
    streamSignal = args.signal;
    await aborted(args.signal!);
  });
  const post = spyOn(Projection, "refreshPublicationSidebar").mockImplementation(async (_oauth, signal) => {
    postSignal = signal;
    return {} as Projection.PublicationSidebarProjection;
  });
  restores.push(() => { stream.mockRestore(); post.mockRestore(); });
  const f = fixture();
  await waitFor(() => expect(calls).toBe(1));
  let failure: unknown;
  act(() => { void f.result.current.refresh.mutateAsync().catch(error => { failure = error; }); });
  await waitFor(() => expect(streamSignal).toBeDefined());
  expect(f.result.current.refresh.isPending).toBe(true);
  expect(streamSignal).toBe(postSignal);
  await act(async () => f.expire());
  await waitFor(() => expect(f.result.current.refresh.isPending).toBe(false));
  expect((failure as Error).name).toBe("TimeoutError");
  expect(f.result.current.projectionError?.message).toContain("Try Refresh again");
  expect(f.client.getQueryData<Projection.PublicationSidebarProjection>(f.sidebarKey)).toEqual(f.projection);
  expect(f.client.getQueryData<typeof f.rows>(f.entriesKey)).toEqual(f.rows);
  stream.mockResolvedValue(undefined);
  await act(async () => { await f.result.current.refresh.mutateAsync(); });
  expect(f.result.current.projectionError).toBeNull();
});

it("expires a stalled POST before starting another bootstrap", async () => {
  const stream = spyOn(Bootstrap, "consumeBootstrapStream").mockResolvedValue(undefined);
  const post = spyOn(Projection, "refreshPublicationSidebar").mockImplementation(async (_oauth, signal) => aborted(signal!));
  restores.push(() => { stream.mockRestore(); post.mockRestore(); });
  const f = fixture();
  await waitFor(() => expect(stream).toHaveBeenCalledTimes(1));
  act(() => { void f.result.current.refresh.mutateAsync().catch(() => undefined); });
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1));
  await act(async () => f.expire());
  await waitFor(() => expect(f.result.current.refresh.isPending).toBe(false));
  expect(stream).toHaveBeenCalledTimes(1);
  expect(f.client.getQueryData<typeof f.rows>(f.entriesKey)).toEqual(f.rows);
});

it.each(["renew", "switchAccount"] as const)("aborts %s work and never starts a late old-account bootstrap", async action => {
  const stream = spyOn(Bootstrap, "consumeBootstrapStream").mockResolvedValue(undefined);
  let finish!: (value: Projection.PublicationSidebarProjection) => void;
  let postSignal: AbortSignal | undefined;
  const post = spyOn(Projection, "refreshPublicationSidebar").mockImplementation(async (_oauth, signal) => {
    postSignal = signal;
    return new Promise(resolve => { finish = resolve; });
  });
  restores.push(() => { stream.mockRestore(); post.mockRestore(); });
  const f = fixture();
  await waitFor(() => expect(stream).toHaveBeenCalledTimes(1));
  act(() => { void f.result.current.refresh.mutateAsync().catch(() => undefined); });
  await waitFor(() => expect(postSignal).toBeDefined());
  act(() => f[action]());
  await waitFor(() => expect(stream).toHaveBeenCalledTimes(2));
  expect(postSignal!.aborted).toBe(true);
  await act(async () => finish(f.projection));
  await waitFor(() => expect(f.result.current.refresh.isPending).toBe(false));
  expect(stream).toHaveBeenCalledTimes(2);
  expect(f.result.current.projectionError).toBeNull();
  expect(f.client.getQueryData<typeof f.rows>(f.entriesKey)).toEqual(f.rows);
});

it("cancels a pending manual stream when its provider unmounts", async () => {
  let calls = 0;
  let signal: AbortSignal | undefined;
  const stream = spyOn(Bootstrap, "consumeBootstrapStream").mockImplementation(async args => {
    if (++calls === 1) return;
    signal = args.signal;
    await aborted(signal!);
  });
  const post = spyOn(Projection, "refreshPublicationSidebar").mockResolvedValue({} as Projection.PublicationSidebarProjection);
  restores.push(() => { stream.mockRestore(); post.mockRestore(); });
  const f = fixture();
  await waitFor(() => expect(calls).toBe(1));
  let result: Promise<unknown> | undefined;
  act(() => { result = f.result.current.refresh.mutateAsync().catch(error => error); });
  await waitFor(() => expect(signal).toBeDefined());
  await act(async () => { f.unmount(); await result; });
  expect(signal!.aborted).toBe(true);
  expect(f.client.getQueryData<typeof f.rows>(f.entriesKey)).toEqual(f.rows);
});

it("settles the deadline even if POST ignores abort, then discards its late completion", async () => {
  const stream = spyOn(Bootstrap, "consumeBootstrapStream").mockResolvedValue(undefined);
  let finish!: (value: Projection.PublicationSidebarProjection) => void;
  const post = spyOn(Projection, "refreshPublicationSidebar").mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  restores.push(() => { stream.mockRestore(); post.mockRestore(); });
  const f = fixture();
  await waitFor(() => expect(stream).toHaveBeenCalledTimes(1));
  let failure: unknown;
  act(() => { void f.result.current.refresh.mutateAsync().catch(error => { failure = error; }); });
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1));
  await act(async () => f.expire());
  await waitFor(() => expect(f.result.current.refresh.isPending).toBe(false));
  expect((failure as Error).name).toBe("TimeoutError");
  await act(async () => finish(f.projection));
  expect(stream).toHaveBeenCalledTimes(1);
  expect(f.client.getQueryData<typeof f.rows>(f.entriesKey)).toEqual(f.rows);
});

it("settles stalled auth/stream work that ignores abort and rejects its late cache events", async () => {
  let calls = 0;
  let handlers: Bootstrap.BootstrapStreamHandlers | undefined;
  let finish!: () => void;
  const stream = spyOn(Bootstrap, "consumeBootstrapStream").mockImplementation(async args => {
    if (++calls === 1) return;
    handlers = args.handlers;
    await new Promise<void>(resolve => { finish = resolve; });
  });
  const post = spyOn(Projection, "refreshPublicationSidebar").mockResolvedValue({} as Projection.PublicationSidebarProjection);
  restores.push(() => { stream.mockRestore(); post.mockRestore(); });
  const f = fixture();
  await waitFor(() => expect(calls).toBe(1));
  act(() => { void f.result.current.refresh.mutateAsync().catch(() => undefined); });
  await waitFor(() => expect(handlers).toBeDefined());
  await act(async () => f.expire());
  await waitFor(() => expect(f.result.current.refresh.isPending).toBe(false));
  expect(f.result.current.sidebarFetching).toBe(false);
  await act(async () => {
    handlers!.onEvent({ kind: "entriesPage", payload: { publicationId: "publication", entries: [{ entryId: "late", title: "Late stale story", publishedAt: "2026-10-16T00:00:00Z" }], source: "live_projection" } });
    handlers!.onEvent({ kind: "done", payload: { refreshedAt: "2026-10-16T00:00:00Z" } });
    finish();
  });
  expect(f.client.getQueryData<typeof f.rows>(f.entriesKey)).toEqual(f.rows);
  expect(f.result.current.bootstrapStreamComplete).toBe(false);
  expect(f.result.current.projectionError?.name).toBe("TimeoutError");
});
