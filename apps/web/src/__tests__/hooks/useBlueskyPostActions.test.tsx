import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Posts from "@/lib/blueskyPostClient";
import { useBlueskyPostEngagement } from "@/hooks/useBlueskyPostEngagement";
import { useBlueskyPostThread } from "@/hooks/useBlueskyPostThread";
const alice = "did:plc:alice";
const bob = "did:plc:bob";
const post = { uri: `at://${bob}/app.bsky.feed.post/one`, cid: "cid", likeCount: 4, repostCount: 2, viewer: {} } as AppBskyFeedDefs.PostView;
const moderation = (did: string) => ({ userDid: did, prefs: { labelers: [] } } as unknown as ModerationOpts);
let viewer: string;
let oauth: string;
let client: QueryClient;
const restores: (() => void)[] = [];
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={client}>{children}</QueryClientProvider>; }
beforeEach(() => {
  viewer = alice; oauth = alice;
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity }, mutations: { retry: false } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, getOAuthSession: () => ({ did: oauth } as OAuthSession), oauthSessionReloadSeq: 0 } as ReturnType<typeof Auth.useAuth>));
  restores.push(() => auth.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).forEach(restore => restore()); });
describe("post action hooks", () => {
  it("waits for thread moderation and rejects mismatched OAuth before fetching", async () => {
    const read = spyOn(Posts, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#notFoundPost", uri: post.uri, notFound: true } }); restores.push(() => read.mockRestore());
    const { result, rerender } = renderHook(({ safety }) => useBlueskyPostThread(post.uri, safety), { initialProps: { safety: undefined as ModerationOpts | undefined }, wrapper: Wrapper });
    expect(read).not.toHaveBeenCalled(); oauth = bob;
    rerender({ safety: moderation(alice) });
    await waitFor(() => expect(result.current.isError).toBe(true));
    expect(read).not.toHaveBeenCalled();
  });
  it("optimistically likes, stores the real interaction URI, and unlikes using that URI", async () => {
    let resolve!: (uri: string | undefined) => void;
    const write = spyOn(Posts, "setBlueskyPostEngagement").mockImplementation(() => new Promise(done => { resolve = done; })); restores.push(() => write.mockRestore());
    const invalidate = spyOn(client, "invalidateQueries"); restores.push(() => invalidate.mockRestore());
    const { result } = renderHook(() => useBlueskyPostEngagement(post, moderation(alice)), { wrapper: Wrapper });
    act(() => { result.current.toggleLike(); result.current.toggleLike(); });
    await waitFor(() => expect(result.current.engagement.likeCount).toBe(5));
    expect(write).toHaveBeenCalledTimes(1);
    const interaction = `at://${alice}/app.bsky.feed.like/actual`;
    await act(async () => { resolve(interaction); });
    await waitFor(() => expect(result.current.engagement.like).toBe(interaction));
    await waitFor(() => expect(result.current.isPending).toBe(false));
    act(() => result.current.toggleLike());
    await waitFor(() => expect(write).toHaveBeenCalledTimes(2));
    expect(write.mock.calls[1]![0].existingUri).toBe(interaction);
    await act(async () => resolve(undefined));
    await waitFor(() => expect(result.current.engagement.likeCount).toBe(4));
    expect(result.current.engagement.like).toBeUndefined();
    expect(invalidate).toHaveBeenCalled();
  });
  it("rolls back failed reposts and isolates late completion after account cleanup", async () => {
    const write = spyOn(Posts, "setBlueskyPostEngagement").mockRejectedValue(new Error("Scope missing")); restores.push(() => write.mockRestore());
    const { result, rerender } = renderHook(({ safety }) => useBlueskyPostEngagement(post, safety), { initialProps: { safety: moderation(alice) }, wrapper: Wrapper });
    act(() => result.current.toggleRepost());
    await waitFor(() => expect(result.current.error?.message).toBe("Scope missing"));
    expect(result.current.engagement).toMatchObject({ repostCount: 2, repost: undefined });
    let resolve!: (uri: string) => void;
    write.mockImplementation(() => new Promise(done => { resolve = done; }));
    act(() => result.current.toggleLike());
    await waitFor(() => expect(result.current.isPending).toBe(true));
    await waitFor(() => expect(write).toHaveBeenCalledTimes(2));
    viewer = bob; oauth = bob;
    act(() => {
      client.removeQueries({ queryKey: ["blueskySocial", alice] });
      rerender({ safety: moderation(bob) });
    });
    await act(async () => {
      resolve(`at://${alice}/app.bsky.feed.like/late`);
      await new Promise(done => setTimeout(done, 10));
    });
    expect(result.current.engagement).toMatchObject({ likeCount: 4, like: undefined });
    expect(result.current.error).toBeNull();
    expect(client.getQueryCache().findAll({ queryKey: ["blueskySocial", alice] })).toHaveLength(0);
  });
});
