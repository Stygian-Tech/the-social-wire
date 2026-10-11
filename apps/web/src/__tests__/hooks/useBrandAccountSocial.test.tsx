import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { AppBskyFeedDefs } from "@atproto/api";
import * as Connection from "@/hooks/useBrandAccounts";
import * as Catalog from "@/lib/blueskySocialClient";
import * as Profile from "@/lib/blueskyProfileClient";
import * as Discovery from "@/lib/blueskySocialDiscoveryClient";
import * as Posts from "@/lib/blueskyPostClient";
import * as Compose from "@/lib/brandAccounts/brandAccountSocialClient";
import { useBrandAccountSocial } from "@/components/BrandAccounts/useBrandAccountSocial";

const restores: (() => void)[] = []; let client: QueryClient; let current: boolean;
const did = "did:plc:brand", owner = "did:plc:owner";
const session = { did } as unknown as OAuthSession;
const post = { uri: "at://did:plc:customer/app.bsky.feed.post/abc", cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", viewer: { like: `at://${did}/app.bsky.feed.like/old` } } as AppBskyFeedDefs.PostView;
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={client}>{children}</QueryClientProvider>; }
beforeEach(() => {
  current = true; client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const connection = spyOn(Connection, "useBrandAccountSession").mockReturnValue({ session, generation: 0, error: undefined, retry: () => {}, assertCurrentActor: () => { if (!current) throw new Error("Acting Account Changed"); } }); restores.push(() => connection.mockRestore());
  const catalog = spyOn(Catalog, "getBlueskySocialCatalog").mockResolvedValue({ feeds: [], moderation: { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } } }); restores.push(() => catalog.mockRestore());
  const agent = spyOn(Catalog, "createAuthenticatedAppViewAgent").mockReturnValue({ app: { bsky: { actor: { getProfile: async () => ({ data: { did, handle: "brand.test" } }) } } } } as unknown as ReturnType<typeof Catalog.createAuthenticatedAppViewAgent>); restores.push(() => agent.mockRestore());
  const profile = spyOn(Profile, "getBlueskyProfilePage").mockResolvedValue({ feed: [] }); restores.push(() => profile.mockRestore());
  const notifications = spyOn(Discovery, "getSocialNotificationsPage").mockResolvedValue({ posts: [], notifications: [] }); restores.push(() => notifications.mockRestore());
  const unread = spyOn(Discovery, "getSocialNotificationUnread").mockResolvedValue(3); restores.push(() => unread.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
it("loads moderation and notifications with the explicit brand session, never the owner", async () => {
  const { result } = renderHook(() => useBrandAccountSocial(owner, did), { wrapper: Wrapper });
  await waitFor(() => expect(result.current.unread.data).toBe(3));
  expect(Catalog.getBlueskySocialCatalog).toHaveBeenCalledWith(session, expect.any(AbortSignal), { includeFeeds: false });
  expect(Discovery.getSocialNotificationsPage).toHaveBeenCalledWith(expect.objectContaining({ session, moderation: expect.objectContaining({ userDid: did }) }));
  expect(client.getQueryCache().getAll().every(query => query.queryKey[0] === "brandAccounts" && query.queryKey[1] === owner && query.queryKey[2] === did)).toBe(true);
});
it("likes/reposts and replies target the brand and prevents late actor writes", async () => {
  const engage = spyOn(Posts, "setBlueskyPostEngagement").mockResolvedValue(undefined); restores.push(() => engage.mockRestore());
  const publish = spyOn(Compose, "publishBrandPost").mockResolvedValue({ uri: `at://${did}/app.bsky.feed.post/new`, cid: post.cid }); restores.push(() => publish.mockRestore());
  const { result } = renderHook(() => useBrandAccountSocial(owner, did), { wrapper: Wrapper });
  await waitFor(() => expect(result.current.moderation).toBeDefined());
  await act(async () => { await result.current.mutation.mutateAsync({ kind: "like", post }); });
  expect(engage).toHaveBeenCalledWith(expect.objectContaining({ session, kind: "like", existingUri: post.viewer!.like, uri: post.uri, cid: post.cid }));
  await act(async () => { await result.current.mutation.mutateAsync({ kind: "repost", post }); });
  await act(async () => { await result.current.mutation.mutateAsync({ kind: "post", text: "Brand Reply", parent: post }); });
  expect(publish).toHaveBeenCalledWith(expect.objectContaining({ session, text: "Brand Reply", parent: post, assertCurrentActor: expect.any(Function) }));
  current = false;
  await act(async () => { await expect(result.current.mutation.mutateAsync({ kind: "post", text: "Wrong Account" })).rejects.toThrow("Changed"); });
  expect(publish).toHaveBeenCalledTimes(1);
});
it("marks only brand notifications seen and keeps action errors inside this workspace", async () => {
  const seen = spyOn(Discovery, "markSocialNotificationsSeen").mockResolvedValue(); restores.push(() => seen.mockRestore());
  const { result } = renderHook(() => useBrandAccountSocial(owner, did), { wrapper: Wrapper });
  await waitFor(() => expect(result.current.moderation).toBeDefined());
  await act(async () => { await result.current.mutation.mutateAsync({ kind: "seen" }); });
  expect(seen).toHaveBeenCalledWith(session, expect.any(String));
});
it("notification-only mode skips the author feed and fails closed without an actor session", async () => {
  const { result, rerender } = renderHook(() => useBrandAccountSocial(owner, did, undefined, { includePosts: false }), { wrapper: Wrapper });
  await waitFor(() => expect(result.current.unread.data).toBe(3));
  expect(Profile.getBlueskyProfilePage).not.toHaveBeenCalled();
  spyOn(Connection, "useBrandAccountSession").mockReturnValue({ session: undefined, generation: 0, error: "Expired", retry: () => {}, assertCurrentActor: () => { throw new Error("Expired"); } });
  rerender(); expect(result.current.moderation).toBeUndefined();
});
