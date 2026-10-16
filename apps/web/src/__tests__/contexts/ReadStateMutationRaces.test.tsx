import { afterEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, fireEvent, renderHook, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider, type InfiniteData } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";
import * as Auth from "@/hooks/useAuth";
import * as Pending from "@/hooks/usePendingPDSReadState";
import * as Runtime from "@/lib/pdsReadStateRuntime";
import * as Thin from "@/lib/thinAppViewClient";
import * as Notice from "@/components/Account/PDSReadStateSyncNotice";
import { ReadStateProvider, useReadState } from "@/contexts/ReadStateContext";
import { effectiveEntryReadState } from "@/lib/pendingReadStateOverlay";
import type { EntriesPage } from "@/hooks/useEntries";
import type { PDSReadStateSync } from "@/lib/pdsReadStateSync";
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).forEach(restore => restore()); window.localStorage.clear(); });
const id = "at://did:plc:author/site.standard.document/article";
const alice = { did: "did:plc:alice" } as unknown as OAuthSession;
const bob = { did: "did:plc:bob" } as unknown as OAuthSession;
function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture(initialRead: boolean, pds = false) {
  let oauth = alice;
  const getOAuthSession = () => oauth;
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const key = ["aggregateEntries", alice.did, "subscribed", "", "all"];
  const page = (isRead: boolean): InfiniteData<EntriesPage> => ({ pages: [{ entries: [{ entryId: id, isRead, title: "Article", publishedAt: "2026-10-16T00:00:00Z" }] }], pageParams: [undefined] });
  client.setQueryData(key, page(initialRead));
  const pending = new Map<string, boolean>();
  let durablePending = false;
  const spies = [
    spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: oauth.did }, getOAuthSession } as ReturnType<typeof Auth.useAuth>)),
    spyOn(Pending, "usePendingPDSReadState").mockImplementation(() => pending),
    spyOn(Runtime, "pdsReadStateEnabled").mockReturnValue(false),
    spyOn(Runtime, "usesPDSReadState").mockResolvedValue(pds),
    spyOn(Runtime, "loadPDSReadStateSync").mockImplementation(async () => ({ snapshot: async () => ({ viewerDid: alice.did, entries: durablePending ? [{ intent: { selection: "exact", state: "unread", subjectUris: [id] } }] : [] }) } as unknown as PDSReadStateSync)),
    spyOn(Notice, "PDSReadStateSyncNotice").mockReturnValue(null),
    spyOn(Thin, "isThinAppViewEnabled").mockReturnValue(true),
  ];
  const read = spyOn(Thin, "writeThroughReadMark").mockResolvedValue();
  const unread = spyOn(Thin, "writeThroughReadMarkDelete").mockResolvedValue();
  restores.push(() => { read.mockRestore(); unread.mockRestore(); spies.forEach(spy => spy.mockRestore()); client.clear(); });
  const hook = renderHook(useReadState, { wrapper: ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}><ReadStateProvider>{children}</ReadStateProvider></QueryClientProvider> });
  const effective = () => effectiveEntryReadState(id, client.getQueryData<InfiniteData<EntriesPage>>(key)?.pages[0].entries[0].isRead, hook.result.current.isEntryRead, hook.result.current.pendingEntryReadState);
  return { ...hook, client, key, page, read, unread, effective,
    setDurablePending(value: boolean) { durablePending = value; if (value) pending.set(id, false); else pending.delete(id); hook.rerender(); },
    switchAccount() { oauth = bob; hook.rerender(); },
    confirm() { window.dispatchEvent(new window.CustomEvent(Runtime.PDS_READ_STATE_SYNC_EVENT, { detail: { viewerDid: alice.did, kind: "confirmed" } })); },
  };
}
it("preserves unread across old requests and 504 refresh, then yields to fresh server data", async () => {
  const env = fixture(true); await act(async () => {});
  const old = deferred<InfiniteData<EntriesPage>>();
  const request = env.client.fetchQuery({ queryKey: env.key, staleTime: 0, queryFn: () => old.promise }).catch(() => {});
  const write = deferred(); env.unread.mockReturnValue(write.promise);
  act(() => env.result.current.markEntryUnread(id));
  expect(env.effective()).toBe(false);
  old.resolve(env.page(true)); await request;
  expect(env.effective()).toBe(false);
  await act(async () => write.resolve());
  await waitFor(() => expect(env.result.current.pendingEntryReadState(id)).toBeUndefined());
  await env.client.fetchQuery({ queryKey: env.key, queryFn: async () => { throw new Error("getFeed 504"); }, staleTime: 0 }).catch(() => {});
  expect(env.effective()).toBe(false);
  act(() => env.client.setQueryData(env.key, env.page(true)));
  expect(env.effective()).toBe(true);
});
it("orders read then unread writes and ignores an earlier completion", async () => {
  const env = fixture(false); await act(async () => {});
  const first = deferred(); const second = deferred();
  env.read.mockReturnValue(first.promise); env.unread.mockReturnValue(second.promise);
  act(() => env.result.current.markEntryRead(id));
  await waitFor(() => expect(env.read).toHaveBeenCalledTimes(1));
  act(() => env.result.current.markEntryUnread(id));
  expect(env.effective()).toBe(false); expect(env.unread).not.toHaveBeenCalled();
  await act(async () => first.resolve());
  await waitFor(() => expect(env.unread).toHaveBeenCalledTimes(1));
  expect(env.effective()).toBe(false);
  await act(async () => second.resolve());
  await waitFor(() => expect(env.result.current.pendingEntryReadState(id)).toBeUndefined());
  expect(env.effective()).toBe(false);
});
it("rolls a failed latest gesture back to accepted state rather than skipped optimism", async () => {
  const env = fixture(false); await act(async () => {});
  env.unread.mockRejectedValue(new Error("offline"));
  act(() => { env.result.current.markEntryRead(id); env.result.current.markEntryUnread(id); });
  await waitFor(() => expect(screen.getByRole("alert")).toBeDefined());
  expect(env.read).not.toHaveBeenCalled(); expect(env.effective()).toBe(false);
  fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
  expect(screen.queryByRole("alert")).toBeNull();
});
it("does not resubmit an already-read gesture", async () => {
  const env = fixture(false); await act(async () => {});
  act(() => env.result.current.markEntryRead(id));
  await waitFor(() => expect(env.read).toHaveBeenCalledTimes(1));
  act(() => env.result.current.markEntryRead(id)); await act(async () => {});
  expect(env.read).toHaveBeenCalledTimes(1);
});
it("isolates a late old-viewer failure from the new account", async () => {
  const env = fixture(true); await act(async () => {});
  const write = deferred(); env.unread.mockReturnValue(write.promise);
  act(() => env.result.current.markEntryUnread(id));
  await waitFor(() => expect(env.unread).toHaveBeenCalledTimes(1));
  act(() => env.switchAccount());
  await act(async () => write.reject(new Error("old viewer offline")));
  expect(env.result.current.pendingEntryReadState(id)).toBeUndefined(); expect(screen.queryByRole("alert")).toBeNull();
});
it("bridges PDS enqueue even if confirmation precedes the write helper return", async () => {
  const env = fixture(true, true); await act(async () => {});
  const write = deferred(); env.unread.mockReturnValue(write.promise);
  act(() => env.result.current.markEntryUnread(id));
  act(() => env.client.setQueryData(env.key, env.page(true)));
  expect(env.effective()).toBe(false);
  act(() => env.confirm());
  await act(async () => write.resolve());
  await waitFor(() => expect(env.result.current.pendingEntryReadState(id)).toBeUndefined());
  expect(env.effective()).toBe(false);
  act(() => env.client.setQueryData(env.key, env.page(true)));
  expect(env.effective()).toBe(true);
});

it("keeps the PDS confirmation bridge until its cached flags are reconciled", async () => {
  const env = fixture(true, true); await act(async () => {});
  act(() => env.setDurablePending(true));
  act(() => env.result.current.markEntryUnread(id));
  await waitFor(() => expect(env.unread).toHaveBeenCalledTimes(1));
  await act(async () => {});
  act(() => env.client.setQueryData(env.key, env.page(true)));
  expect(env.effective()).toBe(false);
  act(() => env.setDurablePending(false));
  expect(env.effective()).toBe(false);
  await act(async () => env.confirm());
  await waitFor(() => expect(env.result.current.pendingEntryReadState(id)).toBeUndefined());
  expect(env.effective()).toBe(false);
});
it("rolls back to an earlier accepted write when the latest opposite action fails", async () => {
  const env = fixture(false); await act(async () => {});
  const first = deferred(); env.read.mockReturnValue(first.promise);
  env.unread.mockRejectedValue(new Error("unread failed"));
  act(() => env.result.current.markEntryRead(id));
  await waitFor(() => expect(env.read).toHaveBeenCalledTimes(1));
  act(() => env.result.current.markEntryUnread(id));
  await act(async () => first.resolve());
  await waitFor(() => expect(screen.getByRole("alert")).toBeDefined());
  expect(env.effective()).toBe(true);
});
