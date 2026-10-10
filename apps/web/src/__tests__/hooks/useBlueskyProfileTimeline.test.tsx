import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Profile from "@/lib/blueskyProfileClient";
import { useBlueskyProfileTimeline } from "@/hooks/useBlueskyProfileTimeline";
const alice = "did:plc:alice";
const bob = "did:plc:bob";
const moderation = (did: string): ModerationOpts => ({ userDid: did, prefs: { labelers: [] }, labelDefs: {} } as unknown as ModerationOpts);
let viewer: string | undefined;
let oauth: string | undefined;
let reload: number;
let client: QueryClient;
const restores: (() => void)[] = [];
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={client}>{children}</QueryClientProvider>; }
beforeEach(() => {
  viewer = alice; oauth = alice; reload = 0;
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: viewer ? { did: viewer } : null, getOAuthSession: () => oauth ? { did: oauth } as OAuthSession : null, oauthSessionReloadSeq: reload } as ReturnType<typeof Auth.useAuth>));
  restores.push(() => auth.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).forEach(restore => restore()); });
describe("profile timeline safety", () => {
  it("waits for moderation and rejects stale OAuth identity before requests", async () => {
    const page = spyOn(Profile, "getBlueskyProfilePage").mockResolvedValue({ feed: [] }); restores.push(() => page.mockRestore());
    const { result, rerender } = renderHook(({ safety }) => useBlueskyProfileTimeline("posts", safety), { initialProps: { safety: undefined as ModerationOpts | undefined }, wrapper: Wrapper });
    expect(page).not.toHaveBeenCalled();
    oauth = bob;
    rerender({ safety: moderation(alice) });
    await waitFor(() => expect(result.current.isError).toBe(true));
    expect(page).not.toHaveBeenCalled();
  });
  it("passes cursor and cancellation signal and stops repeated continuation", async () => {
    const page = spyOn(Profile, "getBlueskyProfilePage").mockResolvedValue({ feed: [], cursor: "same" }); restores.push(() => page.mockRestore());
    const { result } = renderHook(() => useBlueskyProfileTimeline("likes", moderation(alice)), { wrapper: Wrapper });
    await waitFor(() => expect(result.current.hasNextPage).toBe(true));
    await act(async () => { await result.current.fetchNextPage(); });
    expect(page.mock.calls[0]?.[0]).toMatchObject({ session: { did: alice }, tab: "likes", cursor: undefined });
    expect(page.mock.calls[0]?.[0].signal).toBeInstanceOf(AbortSignal);
    expect(page.mock.calls[1]?.[0].cursor).toBe("same");
    await waitFor(() => expect(result.current.hasNextPage).toBe(false));
  });
  it("isolates tabs, viewers, and renewed sessions without old pages", async () => {
    const page = spyOn(Profile, "getBlueskyProfilePage").mockImplementation(async args => args.tab === "posts" && args.session.did === alice && reload === 0 ? { feed: [], cursor: "old" } : new Promise(() => {})); restores.push(() => page.mockRestore());
    const { result, rerender } = renderHook(({ tab, safety }) => useBlueskyProfileTimeline(tab, safety), { initialProps: { tab: "posts" as Profile.ProfileSection, safety: moderation(alice) }, wrapper: Wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.cursor).toBe("old"));
    rerender({ tab: "media", safety: moderation(alice) }); expect(result.current.data).toBeUndefined();
    viewer = bob; oauth = bob;
    rerender({ tab: "posts", safety: moderation(bob) }); expect(result.current.data).toBeUndefined();
    viewer = alice; oauth = alice; reload = 1;
    rerender({ tab: "posts", safety: moderation(alice) }); expect(result.current.data).toBeUndefined();
    expect(client.getQueryCache().getAll().every(query => query.queryKey[0] === "blueskySocial" && query.queryKey[2] === "profileTimeline")).toBe(true);
  });
});
