import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider, type InfiniteData } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";
import * as Auth from "@/hooks/useAuth";
import * as Pending from "@/hooks/usePendingPDSReadState";
import * as Runtime from "@/lib/pdsReadStateRuntime";
import * as Thin from "@/lib/thinAppViewClient";
import * as Telemetry from "@/lib/clientPerformanceTelemetry";
import * as Notice from "@/components/Account/PDSReadStateSyncNotice";
import { ReadStateProvider, useReadState } from "@/contexts/ReadStateContext";
import { useEntries, useAggregateFeedEntries, type EntriesPage } from "@/hooks/useEntries";

const originalEnv = { ...process.env };
const viewer = "did:plc:confirmation-viewer";
const publication = "did:plc:confirmation-publication";
const oauth = { did: viewer } as unknown as OAuthSession;
let activeOAuth = oauth;
let reloadSeq = 0;
const getOAuthSession = () => activeOAuth;
const restores: (() => void)[] = [];
let client: QueryClient;
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}
const row = (entryId: string) => ({ entryId, title: entryId, publishedAt: "2026-10-20T00:00:00Z", isRead: false });
const page = (entryId: string): EntriesPage => ({ entries: [row(entryId)] });
function Wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}
function ReadWrapper({ children }: { children: ReactNode }) {
  return <Wrapper><ReadStateProvider>{children}</ReadStateProvider></Wrapper>;
}
beforeEach(() => {
  process.env.NEXT_PUBLIC_APP_ENV = "production";
  process.env.NEXT_PUBLIC_USE_DUMMY_DATA = "false";
  activeOAuth = oauth;
  reloadSeq = 0;
  client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const overlay = new Map<string, boolean>();
  const spies = [
    spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, getOAuthSession, oauthSessionReloadSeq: reloadSeq } as ReturnType<typeof Auth.useAuth>)),
    spyOn(Pending, "usePendingPDSReadState").mockReturnValue(overlay),
    spyOn(Runtime, "pdsReadStateEnabled").mockReturnValue(false),
    spyOn(Runtime, "usesPDSReadState").mockResolvedValue(false),
    spyOn(Notice, "PDSReadStateSyncNotice").mockReturnValue(null),
    spyOn(Thin, "isThinAppViewEnabled").mockReturnValue(true),
    spyOn(Thin, "fetchAppViewUnreadCounts").mockResolvedValue({ counts: {} }),
    spyOn(Telemetry, "recordClientPerformance").mockResolvedValue(new Response(null, { status: 202 })),
  ];
  restores.push(...spies.map(spy => () => spy.mockRestore()));
});
afterEach(() => {
  cleanup();
  client.clear();
  restores.splice(0).reverse().forEach(restore => restore());
  window.localStorage.clear();
  process.env = { ...originalEnv };
});

function useFeed(scope: "publication" | "subscribed" | "following", filter: "all" | "unread") {
  const publicationFeed = useEntries(scope === "publication" ? publication : null, filter);
  const aggregateFeed = useAggregateFeedEntries(scope === "publication" ? null : { kind: scope }, filter);
  return scope === "publication" ? publicationFeed : aggregateFeed;
}

for (const scope of ["publication", "subscribed", "following"] as const) {
  for (const filter of ["all", "unread"] as const) {
    for (const replaceSession of [false, true]) {
      it(`${scope} accepts current data through installed options after real provider confirmation (${filter}, replace session: ${replaceSession})`, async () => {
        const key = scope === "publication" ? ["entries", viewer, publication, filter] : ["aggregateEntries", viewer, scope, "", filter];
        client.setQueryData<InfiniteData<EntriesPage>>(key, {
          pages: [{ ...page("cached-head"), cursor: "page-two" }, { ...page("cached-tail"), cursor: "page-three" }],
          pageParams: [undefined, "page-two"],
        });
        const beforeConfirmation = deferred<EntriesPage>();
        const afterConfirmation = deferred<EntriesPage>();
        const replacement = deferred<EntriesPage>();
        const write = deferred<void>();
        const feed = spyOn(Thin, "listAggregateFeedFromAppView")
          .mockReturnValueOnce(beforeConfirmation.promise).mockReturnValueOnce(afterConfirmation.promise).mockReturnValueOnce(replacement.promise);
        const mark = spyOn(Thin, "writeThroughReadMark").mockReturnValue(write.promise);
        restores.push(() => feed.mockRestore(), () => mark.mockRestore());
        const controls = renderHook(useReadState, { wrapper: ReadWrapper });
        const hook = renderHook(() => useFeed(scope, filter), { wrapper: Wrapper });
        await act(async () => {});
        act(() => { controls.result.current.markEntryRead("cached-head"); });
        await waitFor(() => expect(mark).toHaveBeenCalledTimes(1));
        let refresh!: Promise<unknown>;
        await act(async () => {
          refresh = hook.result.current.refetch().catch(() => undefined);
          expect(feed).toHaveBeenCalledTimes(1);
          // Resolve the real provider write before React can reinstall observer
          // options. Confirmation cancels, patches flags, and invalidates the feed.
          write.resolve();
          for (let turn = 0; turn < 50; turn++) await Promise.resolve();
        });
        await waitFor(() => expect(feed).toHaveBeenCalledTimes(2));
        expect(feed.mock.calls[0][0].signal?.aborted).toBe(true);
        expect(feed.mock.calls[1][0].signal?.aborted).toBe(false);
        if (replaceSession) {
          activeOAuth = { did: viewer } as unknown as OAuthSession;
          reloadSeq++;
          hook.rerender();
          await waitFor(() => expect(feed).toHaveBeenCalledTimes(3));
          expect(feed.mock.calls[1][0].signal?.aborted).toBe(true);
          expect(feed.mock.calls[2][0].signal?.aborted).toBe(false);
        }
        await act(async () => { (replaceSession ? replacement : afterConfirmation).resolve(page("confirmed-fresh")); });
        const ids = () => hook.result.current.data?.pages.flatMap(value => value.entries.map(entry => entry.entryId));
        const expected = filter === "all" ? ["confirmed-fresh", "cached-head", "cached-tail"] : ["confirmed-fresh"];
        await waitFor(() => expect(ids()).toEqual(expected));
        await act(async () => {
          beforeConfirmation.resolve(page("late-before-confirmation"));
          if (replaceSession) afterConfirmation.resolve(page("old-session-confirmation"));
          await refresh;
        });
        expect(ids()).toEqual(expected);
        expect(hook.result.current.isFetching).toBe(false);
        expect(hook.result.current.isError).toBe(false);
        expect(client.getQueryState(key)?.isInvalidated).toBe(false);
        if (filter === "all") {
          expect(hook.result.current.data?.pages[0].entries.find(entry => entry.entryId === "cached-head")?.isRead).toBe(true);
          expect(hook.result.current.data?.pageParams).toEqual([undefined, "page-two"]);
        }
      });
    }
  }
}
