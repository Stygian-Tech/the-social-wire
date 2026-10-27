import { afterEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider, type InfiniteData } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";
import * as Auth from "@/hooks/useAuth";
import * as Runtime from "@/lib/pdsReadStateRuntime";
import * as Pending from "@/hooks/usePendingPDSReadState";
import * as Notice from "@/components/Account/PDSReadStateSyncNotice";
import * as Thin from "@/lib/thinAppViewClient";
import * as Projection from "@/lib/publicationProjectionClient";
import { ReadRouteProvider, useReadRoute } from "@/contexts/ReadRouteContext";
import { useCachedBulkReadActions } from "@/hooks/useCachedBulkReadActions";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { READ_STATE_STORAGE_KEY } from "@/lib/entryReadStateStorage";
import { effectiveEntryReadState } from "@/lib/pendingReadStateOverlay";
import type { EntriesPage } from "@/hooks/useEntries";
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).forEach(restore => restore()); window.localStorage.clear(); });
const alice = { did: "did:plc:alice" } as unknown as OAuthSession;
const bob = { did: "did:plc:bob" } as unknown as OAuthSession;
const entryId = "at://did:plc:author/site.standard.document/article";
const publication = { publicationId: "did:plc:author", authorDid: "did:plc:author", authorHandle: "author.test", title: "Author", discoveredAt: "2026-10-16T00:00:00Z" };
function deferred<T>() {
  let resolve!: (value: T) => void; let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture(previouslyRead = false) {
  let oauth = alice; const getOAuthSession = () => oauth;
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const key = ["entries", alice.did, publication.publicationId, "all"];
  const page: InfiniteData<EntriesPage> = { pages: [{ entries: [{ entryId, title: "Article", publishedAt: "2026-10-16T00:00:00Z", isRead: previouslyRead }] }], pageParams: [undefined] };
  client.setQueryData(key, page);
  if (previouslyRead) window.localStorage.setItem(READ_STATE_STORAGE_KEY, JSON.stringify({ [entryId]: "2026-10-15T00:00:00Z" }));
  const bulk = deferred<Awaited<ReturnType<typeof Projection.markAllReadOnGateway>>>();
  const gateway = spyOn(Projection, "markAllReadOnGateway").mockReturnValue(bulk.promise);
  const unread = spyOn(Thin, "writeThroughReadMarkDelete").mockResolvedValue();
  const spies = [
    spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: oauth.did }, getOAuthSession } as ReturnType<typeof Auth.useAuth>)),
    spyOn(Runtime, "pdsReadStateEnabled").mockReturnValue(false),
    spyOn(Runtime, "usesPDSReadState").mockResolvedValue(false),
    spyOn(Pending, "usePendingPDSReadState").mockReturnValue(new Map()),
    spyOn(Notice, "PDSReadStateSyncNotice").mockReturnValue(null),
    spyOn(Thin, "isThinAppViewEnabled").mockReturnValue(true),
    unread, gateway,
  ];
  restores.push(() => { spies.forEach(spy => spy.mockRestore()); client.clear(); });
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}><ReadRouteProvider>{children}</ReadRouteProvider></QueryClientProvider>;
  const mount = () => renderHook(() => ({ bulk: useCachedBulkReadActions([publication]), otherBulk: useCachedBulkReadActions([publication]), state: useReadRoute() }), { wrapper });
  return { client, key, page, bulk, mount, gateway, unread, switchAccount() { oauth = bob; }, renewSession() { oauth = { did: alice.did } as unknown as OAuthSession; },
    confirmation: { marked: 1, boundaries: [], confirmedAt: "2026-10-16T01:00:00Z", unreadCounts: { [publication.publicationId]: 0 } },
  };
}
for (const outcome of ["success", "failure"] as const) {
  it(`keeps a newer single unread through stale bulk ${outcome} and navigation`, async () => {
    const env = fixture(true); const hook = env.mount(); await act(async () => {});
    act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
    act(() => hook.result.current.state.markEntryUnread(entryId));
    await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(entryId)).toBeUndefined());
    expect(hook.result.current.state.isEntryRead(entryId)).toBe(false);
    await act(async () => { if (outcome === "success") env.bulk.resolve(env.confirmation); else env.bulk.reject(new Error("bulk failed")); });
    expect(hook.result.current.state.isEntryRead(entryId)).toBe(false);
    expect(env.client.getQueryData<InfiniteData<EntriesPage>>(env.key)?.pages[0].entries[0].isRead).toBe(false);
    hook.unmount(); const navigation = env.mount(); await act(async () => {});
    expect(effectiveEntryReadState(entryId, false, navigation.result.current.state.isEntryRead, navigation.result.current.state.pendingEntryReadState)).toBe(false);
  });
}
it("ignores a late bulk completion after switching OAuth accounts", async () => {
  const env = fixture(); const hook = env.mount(); await act(async () => {});
  act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
  act(() => hook.result.current.state.markEntryUnread(entryId));
  await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(entryId)).toBeUndefined());
  act(() => { env.switchAccount(); hook.rerender(); });
  await act(async () => env.bulk.resolve(env.confirmation));
  expect(hook.result.current.state.isEntryRead(entryId)).toBe(false);
  expect(env.client.getQueryData<InfiniteData<EntriesPage>>(env.key)?.pages[0].entries[0].isRead).toBe(false);
});

it("defers bulk changes until confirmation while preserving the newer unread and fresh cache rows", async () => {
  const env = fixture(true);
  const otherId = "at://did:plc:author/site.standard.document/other";
  env.client.setQueryData<InfiniteData<EntriesPage>>(env.key, { ...env.page, pages: [{ entries: [
    ...env.page.pages[0].entries, { entryId: otherId, title: "Other", publishedAt: "2026-10-16T00:00:00Z", isRead: false },
  ] }] });
  const hook = env.mount(); await act(async () => {});
  act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
  expect(hook.result.current.state.isEntryRead(otherId)).toBe(false);
  act(() => hook.result.current.state.markEntryUnread(entryId));
  await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(entryId)).toBeUndefined());
  act(() => env.client.setQueryData<InfiniteData<EntriesPage>>(env.key, current => ({ ...current!, pages: [{ entries: [
    ...current!.pages[0].entries, { entryId: "new-row", title: "Fresh", publishedAt: "2026-10-16T02:00:00Z", isRead: false },
  ] }] })));
  await act(async () => env.bulk.reject(new Error("bulk failed")));
  await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(otherId)).toBeUndefined());
  expect(hook.result.current.state.isEntryRead(entryId)).toBe(false);
  expect(hook.result.current.state.isEntryRead(otherId)).toBe(false);
  expect(env.client.getQueryData<InfiniteData<EntriesPage>>(env.key)?.pages[0].entries.map(entry => entry.entryId)).toEqual([entryId, otherId, "new-row"]);
  hook.unmount(); const navigation = env.mount(); await act(async () => {});
  expect(navigation.result.current.state.isEntryRead(otherId)).toBe(false);
});
it("applies confirmed bulk authority to untouched entries while excluding a newly cached explicit unread", async () => {
  const env = fixture(); const hook = env.mount(); await act(async () => {});
  act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
  const lateId = "at://did:plc:author/site.standard.document/late";
  act(() => env.client.setQueryData<InfiniteData<EntriesPage>>(env.key, current => ({ ...current!, pages: [{ entries: [
    ...current!.pages[0].entries, { entryId: lateId, title: "Late", publishedAt: "2026-10-16T00:00:00Z", isRead: false },
  ] }] })));
  act(() => hook.result.current.state.markEntryUnread(lateId));
  await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(lateId)).toBeUndefined());
  await act(async () => env.bulk.resolve(env.confirmation));
  expect(hook.result.current.state.isEntryRead(entryId)).toBe(true);
  expect(hook.result.current.state.isEntryRead(lateId)).toBe(false);
});

it("disables the bulk action while pending and ignores duplicate activation without blocking single unread", async () => {
  const env = fixture(); const hook = env.mount(); await act(async () => {});
  expect(hook.result.current.bulk.bulkDisabled).toBe(false);
  act(() => { hook.result.current.bulk.applyMarkAllRead(); hook.result.current.bulk.applyMarkAllRead(); });
  expect(hook.result.current.bulk.bulkDisabled).toBe(true); expect(env.gateway).toHaveBeenCalledTimes(1);
  act(() => hook.result.current.state.markEntryUnread(entryId));
  await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(entryId)).toBeUndefined());
  await act(async () => env.bulk.resolve(env.confirmation));
  expect(hook.result.current.bulk.bulkDisabled).toBe(false);
  expect(hook.result.current.state.isEntryRead(entryId)).toBe(false);
});
it("preserves an authoritative cached read baseline when no local read mark exists", async () => {
  const env = fixture();
  env.client.setQueryData<InfiniteData<EntriesPage>>(env.key, { ...env.page, pages: [{ entries: [{ ...env.page.pages[0].entries[0], isRead: true }] }] });
  const hook = env.mount(); await act(async () => {});
  expect(hook.result.current.state.isEntryRead(entryId)).toBe(false);
  act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
  await act(async () => env.bulk.reject(new Error("bulk failed")));
  expect(env.unread).not.toHaveBeenCalled();
  expect(effectiveEntryReadState(entryId, env.client.getQueryData<InfiniteData<EntriesPage>>(env.key)?.pages[0].entries[0].isRead,
    hook.result.current.state.isEntryRead, hook.result.current.state.pendingEntryReadState)).toBe(true);
});
it("uses pending explicit unread ahead of an older authoritative-looking cached read baseline", async () => {
  const env = fixture(); const hook = env.mount(); await act(async () => {});
  const pending = deferred<void>(); env.unread.mockReturnValueOnce(pending.promise);
  act(() => hook.result.current.state.markEntryUnread(entryId));
  await waitFor(() => expect(env.unread).toHaveBeenCalledTimes(1));
  act(() => env.client.setQueryData<InfiniteData<EntriesPage>>(env.key, { ...env.page, pages: [{ entries: [{ ...env.page.pages[0].entries[0], isRead: true }] }] }));
  act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
  await act(async () => env.bulk.reject(new Error("bulk failed")));
  await act(async () => pending.resolve());
  await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(entryId)).toBeUndefined());
  expect(hook.result.current.state.isEntryRead(entryId)).toBe(false);
  expect(env.unread).toHaveBeenCalledTimes(1);
});

it("shares pending ownership across toolbar/sidebar hooks while a newer unread survives failure", async () => {
  const env = fixture(true); const hook = env.mount(); await act(async () => {});
  act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
  expect(hook.result.current.otherBulk.bulkDisabled).toBe(true);
  act(() => { void hook.result.current.otherBulk.applyMarkAllRead(); });
  expect(env.gateway).toHaveBeenCalledTimes(1);
  act(() => hook.result.current.state.markEntryUnread(entryId));
  await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(entryId)).toBeUndefined());
  await act(async () => env.bulk.reject(new Error("bulk failed")));
  expect(hook.result.current.bulk.bulkDisabled).toBe(false);
  expect(hook.result.current.otherBulk.bulkDisabled).toBe(false);
  expect(hook.result.current.state.isEntryRead(entryId)).toBe(false);
});
it("isolates renewed OAuth ownership and an old session's eventual release", async () => {
  const env = fixture(); const hook = env.mount(); await act(async () => {});
  act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
  const next = deferred<Awaited<ReturnType<typeof Projection.markAllReadOnGateway>>>();
  env.gateway.mockReturnValue(next.promise);
  act(() => { env.renewSession(); hook.rerender(); });
  expect(hook.result.current.bulk.bulkDisabled).toBe(false);
  act(() => { void hook.result.current.otherBulk.applyMarkAllRead(); });
  expect(env.gateway).toHaveBeenCalledTimes(2);
  expect(hook.result.current.bulk.bulkDisabled).toBe(true);
  await act(async () => env.bulk.resolve(env.confirmation));
  expect(hook.result.current.bulk.bulkDisabled).toBe(true);
  await act(async () => next.resolve(env.confirmation));
  expect(hook.result.current.bulk.bulkDisabled).toBe(false);
});

it("does not replace a fresh publication badge with stale mixed-rollback deltas", async () => {
  const env = fixture(true); const otherId = "at://did:plc:author/site.standard.document/other";
  env.client.setQueryData<InfiniteData<EntriesPage>>(env.key, { ...env.page, pages: [{ entries: [
    ...env.page.pages[0].entries, { entryId: otherId, title: "Other", publishedAt: "2026-10-16T00:00:00Z", isRead: false },
  ] }] });
  const hook = env.mount(); await act(async () => {});
  act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
  act(() => hook.result.current.state.markEntryUnread(entryId));
  await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(entryId)).toBeUndefined());
  const badgeKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(alice.did);
  act(() => env.client.setQueryData<PublicationSidebarProjection>(badgeKey, {
    viewerDid: alice.did, folders: [], publicationPrefs: [], folderSections: [], allPublicationRows: [],
    myPublications: [], subscribedUnfoldered: [], followingTabPublications: [], enrollAuthorDids: [],
    unreadCountsByPublicationId: { [publication.publicationId]: 9 }, refreshedAt: "2026-10-16T02:00:00Z",
  }));
  await act(async () => env.bulk.reject(new Error("bulk failed")));
  await waitFor(() => expect(hook.result.current.state.pendingEntryReadState(otherId)).toBeUndefined());
  expect(env.client.getQueryData<PublicationSidebarProjection>(badgeKey)?.unreadCountsByPublicationId?.[publication.publicationId]).toBe(9);
  expect(hook.result.current.state.isEntryRead(entryId)).toBe(false);
  expect(hook.result.current.state.isEntryRead(otherId)).toBe(false);
});

it("ignores a bulk confirmation after its initiating hook unmounts", async () => {
  const env = fixture(); const hook = env.mount(); await act(async () => {});
  act(() => { void hook.result.current.bulk.applyMarkAllRead(); });
  hook.unmount();
  await act(async () => env.bulk.resolve(env.confirmation));
  expect(env.client.getQueryData<InfiniteData<EntriesPage>>(env.key)).toEqual(env.page);
  expect(env.unread).not.toHaveBeenCalled();
});
