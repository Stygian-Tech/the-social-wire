import { afterEach, expect, it, spyOn } from "bun:test";
import { QueryClient, type InfiniteData } from "@tanstack/react-query";
import { writeStreamedEntriesPage } from "@/lib/bootstrapStreamState";
import { invalidateReadFeedRefreshes, readFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";
import { ENTRIES_QUERY_KEY, type EntriesPage } from "@/hooks/useEntries";
import { createElement, type ReactNode } from "react";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClientProvider } from "@tanstack/react-query";
import * as Auth from "@/hooks/useAuth";
import * as Bootstrap from "@/lib/bootstrapStreamClient";
import { PublicationSidebarProvider, useSidebarBootstrap } from "@/contexts/PublicationSidebarContext";

const viewer = "did:plc:bootstrap-race";
const publicationId = "at://did:plc:author/site.standard.publication/one";
const entry = { entryId: "at://did:plc:author/site.standard.document/one", title: "One", publishedAt: "2026-10-16T00:00:00Z" };
const key = [...ENTRIES_QUERY_KEY(viewer, publicationId), "all"];
const clients: QueryClient[] = [];
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); clients.splice(0).forEach(client => client.clear()); restores.splice(0).forEach(restore => restore()); });

function fixture() {
  const client = new QueryClient(); clients.push(client);
  const session = {};
  client.setQueryData(key, { pages: [{ entries: [{ ...entry, isRead: false }] }], pageParams: [undefined] });
  const isRead = () => client.getQueryData<InfiniteData<EntriesPage>>(key)?.pages[0].entries[0]?.isRead;
  return { client, session, isRead };
}

it("rejects a bootstrap begun before unread, even after its acknowledgement retires the overlay", () => {
  const { client, session, isRead } = fixture();
  const revision = readFeedRefreshRevision(client, session);
  invalidateReadFeedRefreshes(client, session); // Explicit unread gesture.
  invalidateReadFeedRefreshes(client, session); // Acknowledgement and cache reconciliation.
  writeStreamedEntriesPage(client, viewer, {
    publicationId, entries: [entry], source: "live_projection",
  }, "all", { session, revision });
  expect(isRead()).toBe(false);
});

it("accepts a new stream after acknowledgement even when its content cache predates the mutation", () => {
  const { client, session, isRead } = fixture();
  invalidateReadFeedRefreshes(client, session);
  invalidateReadFeedRefreshes(client, session);
  // A new provider/stream captures the current revision after acknowledgement.
  const snapshot = { session, revision: readFeedRefreshRevision(client, session) };
  writeStreamedEntriesPage(client, viewer, {
    publicationId, entries: [entry], source: "projection_cache", cachedAt: "2026-10-16T05:59:59Z",
  }, "all", snapshot);
  expect(isRead()).toBeUndefined();
  // Future read-state-bearing payloads can still update authoritative flags.
  writeStreamedEntriesPage(client, viewer, {
    publicationId, entries: [{ ...entry, isRead: true }], source: "live_projection",
  }, "all", snapshot);
  expect(isRead()).toBe(true);
});

it("does not retire another OAuth session's stream revision", () => {
  const { client, session, isRead } = fixture();
  invalidateReadFeedRefreshes(client, session);
  const otherSession = {};
  writeStreamedEntriesPage(client, viewer, {
    publicationId, entries: [{ ...entry, isRead: true }], source: "projection_cache", cachedAt: "2026-10-16T05:59:59Z",
  }, "all", { session: otherSession, revision: 0 });
  expect(isRead()).toBe(true);
});

it("retires delayed stream entries while preserving sidebar completion and publication selection", async () => {
  const { client, isRead } = fixture();
  const oauth = { did: viewer } as unknown as ReturnType<ReturnType<typeof Auth.useAuth>["getOAuthSession"]>;
  if (!oauth) throw new Error("missing fixture session");
  const auth = spyOn(Auth, "useAuth").mockReturnValue({
    session: { did: viewer }, getOAuthSession: () => oauth, oauthSessionReloadSeq: 0,
  } as ReturnType<typeof Auth.useAuth>);
  let handlers: Bootstrap.BootstrapStreamHandlers | undefined;
  let finish!: () => void;
  const stream = spyOn(Bootstrap, "consumeBootstrapStream").mockImplementation(async args => {
    handlers = args.handlers;
    await new Promise<void>(resolve => { finish = resolve; });
  });
  restores.push(() => { auth.mockRestore(); stream.mockRestore(); });
  const hook = renderHook(useSidebarBootstrap, { wrapper: ({ children }: { children: ReactNode }) =>
    createElement(QueryClientProvider, { client }, createElement(PublicationSidebarProvider, null, children)) });
  await waitFor(() => expect(handlers).toBeDefined());
  invalidateReadFeedRefreshes(client, oauth);
  invalidateReadFeedRefreshes(client, oauth);
  await act(async () => {
    handlers!.onEvent({ kind: "selectedPublication", payload: { publicationId } });
    handlers!.onEvent({ kind: "entriesPage", payload: {
      publicationId, entries: [entry], source: "live_projection",
    } });
    handlers!.onEvent({ kind: "done", payload: { refreshedAt: "2026-10-16T06:00:03Z" } });
    finish();
  });
  expect(isRead()).toBe(false);
  expect(hook.result.current.bootstrapStreamComplete).toBe(true);
  expect(hook.result.current.streamSelectedPublicationId).toBe(publicationId);
});
