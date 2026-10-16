import { afterEach, expect, it, spyOn } from "bun:test";
import { QueryClient, QueryClientProvider, type InfiniteData } from "@tanstack/react-query";
import { act, cleanup, renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { useAggregateFeedEntries } from "@/hooks/useEntries";
import * as Auth from "@/hooks/useAuth";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { coalesceFeedFirstPage, invalidateReadFeedRefreshes, readFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";
import { refreshPublicationFeedFirstPage } from "@/lib/feedRefresh";
import * as Thin from "@/lib/thinAppViewClient";
import type { EntriesPage } from "@/hooks/useEntries";
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).forEach(restore => restore()); });
it("retires only read-feed work for the captured client and OAuth session", async () => {
  const client = new QueryClient(); const oauth = {}; const other = {};
  let finish!: (value: string) => void;
  const key = ["aggregateEntries", "viewer", "subscribed", "", "all"];
  const old = coalesceFeedFirstPage(client, oauth, key, () => new Promise<string>(resolve => { finish = resolve; }));
  const revision = readFeedRefreshRevision(client, oauth);
  invalidateReadFeedRefreshes(client, oauth);
  expect(readFeedRefreshRevision(client, oauth)).toBe(revision + 1);
  expect(readFeedRefreshRevision(client, other)).toBe(0);
  expect(await coalesceFeedFirstPage(client, oauth, key, async () => "current")).toBe("current");
  finish("old"); expect(await old).toBe("old");
  client.clear();
});
it("does not let a manual publication refresh replace a newer explicit unread state", async () => {
  const client = new QueryClient();
  const oauth = { did: "did:plc:reader" } as unknown as OAuthSession;
  const publicationId = "at://did:plc:author/site.standard.publication/main";
  const key = ["entries", oauth.did, publicationId, "all"];
  const row = { entryId: "article", title: "Article", publishedAt: "2026-10-16T00:00:00Z", isRead: true };
  client.setQueryData(key, { pages: [{ entries: [row] }], pageParams: [undefined] });
  let finish!: (value: EntriesPage) => void;
  const fetch = spyOn(Thin, "listAggregateFeedFromAppView").mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  restores.push(() => { fetch.mockRestore(); client.clear(); });
  const args = { queryClient: client, publicationKey: publicationId, viewerDid: oauth.did, oauthSession: oauth };
  const refresh = refreshPublicationFeedFirstPage(args);
  invalidateReadFeedRefreshes(client, oauth);
  client.setQueryData(key, { pages: [{ entries: [{ ...row, isRead: false }] }], pageParams: [undefined] });
  finish({ entries: [row] });
  expect(await refresh).toBe(false);
  expect(client.getQueryData<InfiniteData<EntriesPage>>(key)?.pages[0].entries[0].isRead).toBe(false);
});

it("ignores a late aggregate manual refresh after a read mutation retires it", async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const oauth = { did: "did:plc:reader" } as unknown as OAuthSession;
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession: () => oauth } as ReturnType<typeof Auth.useAuth>);
  const key = ["aggregateEntries", oauth.did, "subscribed", "", "all"];
  const row = { entryId: "article", title: "Article", publishedAt: "2026-10-16T00:00:00Z", isRead: true };
  client.setQueryData(key, { pages: [{ entries: [row] }], pageParams: [undefined] });
  let finish!: (page: EntriesPage) => void;
  const fetch = spyOn(Thin, "listAggregateFeedFromAppView").mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  restores.push(() => { auth.mockRestore(); fetch.mockRestore(); client.clear(); });
  const { result } = renderHook(() => useAggregateFeedEntries({ kind: "subscribed" }), {
    wrapper: ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>,
  });
  let refresh!: ReturnType<typeof result.current.refetch>;
  act(() => { refresh = result.current.refetch(); });
  invalidateReadFeedRefreshes(client, oauth);
  act(() => client.setQueryData(key, { pages: [{ entries: [{ ...row, isRead: false }] }], pageParams: [undefined] }));
  finish({ entries: [row] });
  await act(async () => { await refresh; });
  expect(client.getQueryData<InfiniteData<EntriesPage>>(key)?.pages[0].entries[0].isRead).toBe(false);
});
