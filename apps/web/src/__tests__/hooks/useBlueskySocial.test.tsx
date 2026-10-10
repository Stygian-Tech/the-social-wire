import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";

import * as Auth from "@/hooks/useAuth";
import * as Client from "@/lib/blueskySocialClient";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useBlueskySocialTimeline } from "@/hooks/useBlueskySocialTimeline";

const alice = "did:plc:alice";
const bob = "did:plc:bob";
const custom: Client.SocialFeed = { kind: "feed", uri: "at://did:plc:alice/app.bsky.feed.generator/news", name: "News", pinned: true };
const moderation = (did: string): ModerationOpts => ({ userDid: did, prefs: { labelers: [] }, labelDefs: {} } as unknown as ModerationOpts);
const page = (uri: string, cursor?: string): Client.BlueskySocialPage => ({ feed: [{ post: { uri } }] as Client.BlueskySocialPage["feed"], cursor });

let viewerDid: string | undefined;
let oauthDid: string | undefined;
let reloadSeq: number;
let queryClient: QueryClient;
let restoreAuth: () => void;
const restores: (() => void)[] = [];

function Wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
}

function waitUntilAborted(signal?: AbortSignal): Promise<never> {
  return new Promise((_resolve, reject) => {
    signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true });
  });
}

beforeEach(() => {
  viewerDid = alice;
  oauthDid = alice;
  reloadSeq = 0;
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({
    session: viewerDid ? { did: viewerDid } : null,
    getOAuthSession: () => oauthDid ? { did: oauthDid } as OAuthSession : null,
    oauthSessionReloadSeq: reloadSeq,
  } as ReturnType<typeof Auth.useAuth>));
  restoreAuth = () => auth.mockRestore();
});
afterEach(() => {
  cleanup();
  queryClient.clear();
  restores.splice(0).forEach(restore => restore());
  restoreAuth();
});

describe("Bluesky Social query safety", () => {
  it("leaves catalog requests disabled until the sidebar is opened", async () => {
    const catalog = spyOn(Client, "getBlueskySocialCatalog").mockResolvedValue({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: moderation(alice) });
    restores.push(() => catalog.mockRestore());
    const { result, rerender } = renderHook(({ enabled }) => useBlueskySocialCatalog({ enabled }), { initialProps: { enabled: false }, wrapper: Wrapper });
    expect(catalog).not.toHaveBeenCalled();
    rerender({ enabled: true });
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(catalog.mock.calls[0]?.[0].did).toBe(alice);
    expect(catalog.mock.calls[0]?.[1]).toBeInstanceOf(AbortSignal);
  });

  it("does not request a timeline when the moderation catalog fails", async () => {
    const catalog = spyOn(Client, "getBlueskySocialCatalog").mockRejectedValue(new Error("Moderation unavailable"));
    const timeline = spyOn(Client, "getBlueskySocialPage").mockResolvedValue(page("never"));
    restores.push(() => catalog.mockRestore(), () => timeline.mockRestore());
    const { result } = renderHook(() => {
      const settings = useBlueskySocialCatalog();
      const posts = useBlueskySocialTimeline(Client.SOCIAL_FOLLOWING_FEED, settings.data?.moderation);
      return { settings, posts };
    }, { wrapper: Wrapper });
    await waitFor(() => expect(result.current.settings.isError).toBe(true));
    expect(timeline).not.toHaveBeenCalled();
    expect(result.current.posts.data).toBeUndefined();
  });

  it("rejects a changed OAuth identity before invoking either client", async () => {
    oauthDid = bob;
    const catalog = spyOn(Client, "getBlueskySocialCatalog").mockResolvedValue({ feeds: [], moderation: moderation(alice) });
    const timeline = spyOn(Client, "getBlueskySocialPage").mockResolvedValue(page("never"));
    restores.push(() => catalog.mockRestore(), () => timeline.mockRestore());
    const { result } = renderHook(() => ({ catalog: useBlueskySocialCatalog(), timeline: useBlueskySocialTimeline(Client.SOCIAL_FOLLOWING_FEED, moderation(alice)) }), { wrapper: Wrapper });
    await waitFor(() => expect(result.current.catalog.isError && result.current.timeline.isError).toBe(true));
    expect(catalog).not.toHaveBeenCalled();
    expect(timeline).not.toHaveBeenCalled();
  });

  it("does not show prior posts when changing feeds or viewers", async () => {
    const timeline = spyOn(Client, "getBlueskySocialPage").mockImplementation(async args => {
      if (args.session.did === alice && args.feed.kind === "following") return page("at://alice/old-post");
      return waitUntilAborted(args.signal);
    });
    restores.push(() => timeline.mockRestore());
    const { result, rerender } = renderHook(({ feed, safety }) => useBlueskySocialTimeline(feed, safety), { initialProps: { feed: Client.SOCIAL_FOLLOWING_FEED, safety: moderation(alice) }, wrapper: Wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.feed[0]?.post.uri).toBe("at://alice/old-post"));
    rerender({ feed: custom, safety: moderation(alice) });
    expect(result.current.data).toBeUndefined();
    await waitFor(() => expect(timeline.mock.calls.length).toBe(2));
    const customSignal = timeline.mock.calls[1]?.[0].signal;
    viewerDid = bob;
    oauthDid = bob;
    rerender({ feed: Client.SOCIAL_FOLLOWING_FEED, safety: moderation(bob) });
    expect(result.current.data).toBeUndefined();
    await waitFor(() => expect(customSignal?.aborted).toBe(true));
    await waitFor(() => expect(timeline.mock.calls[2]?.[0].session.did).toBe(bob));
  });

  it("blocks old moderation settings after the viewer changes", async () => {
    viewerDid = bob;
    oauthDid = bob;
    const timeline = spyOn(Client, "getBlueskySocialPage").mockResolvedValue(page("never"));
    restores.push(() => timeline.mockRestore());
    const { result } = renderHook(() => useBlueskySocialTimeline(Client.SOCIAL_FOLLOWING_FEED, moderation(alice)), { wrapper: Wrapper });
    expect(result.current.fetchStatus).toBe("idle");
    expect(timeline).not.toHaveBeenCalled();
  });

  it("passes and aborts catalog and timeline requests when unmounted", async () => {
    const catalog = spyOn(Client, "getBlueskySocialCatalog").mockImplementation((_session, signal) => waitUntilAborted(signal));
    const timeline = spyOn(Client, "getBlueskySocialPage").mockImplementation(args => waitUntilAborted(args.signal));
    restores.push(() => catalog.mockRestore(), () => timeline.mockRestore());
    const { unmount } = renderHook(() => ({ catalog: useBlueskySocialCatalog(), timeline: useBlueskySocialTimeline(Client.SOCIAL_FOLLOWING_FEED, moderation(alice)) }), { wrapper: Wrapper });
    await waitFor(() => expect(catalog.mock.calls.length + timeline.mock.calls.length).toBe(2));
    const catalogSignal = catalog.mock.calls[0]?.[1];
    const timelineSignal = timeline.mock.calls[0]?.[0].signal;
    expect(catalogSignal?.aborted).toBe(false);
    expect(timelineSignal?.aborted).toBe(false);
    unmount();
    expect(catalogSignal?.aborted).toBe(true);
    expect(timelineSignal?.aborted).toBe(true);
  });

  it("stops pagination when the server repeats its previous cursor", async () => {
    const timeline = spyOn(Client, "getBlueskySocialPage").mockImplementation(async args => page(args.cursor ? "second" : "first", "repeat"));
    restores.push(() => timeline.mockRestore());
    const { result } = renderHook(() => useBlueskySocialTimeline(Client.SOCIAL_FOLLOWING_FEED, moderation(alice)), { wrapper: Wrapper });
    await waitFor(() => expect(result.current.hasNextPage).toBe(true));
    await act(async () => { await result.current.fetchNextPage(); });
    await waitFor(() => expect(result.current.hasNextPage).toBe(false));
    await act(async () => { await result.current.fetchNextPage(); });
    expect(timeline.mock.calls.map(([args]) => args.cursor)).toEqual([undefined, "repeat"]);
    expect(result.current.data?.pages).toHaveLength(2);
  });

  it("starts a fresh query when OAuth reconnects for the same viewer", async () => {
    const timeline = spyOn(Client, "getBlueskySocialPage").mockResolvedValueOnce(page("old-session")).mockImplementation(args => waitUntilAborted(args.signal));
    restores.push(() => timeline.mockRestore());
    const { result, rerender } = renderHook(() => useBlueskySocialTimeline(Client.SOCIAL_FOLLOWING_FEED, moderation(alice)), { wrapper: Wrapper });
    await waitFor(() => expect(result.current.data?.pages[0]?.feed[0]?.post.uri).toBe("old-session"));
    reloadSeq += 1;
    rerender();
    expect(result.current.data).toBeUndefined();
    await waitFor(() => expect(timeline).toHaveBeenCalledTimes(2));
  });
});
