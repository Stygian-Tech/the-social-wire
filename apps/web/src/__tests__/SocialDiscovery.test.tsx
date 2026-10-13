import * as Tools from "@/lib/toolsEnabled";
import * as Brands from "@/hooks/useBrandAccounts";
import * as BrandNotifications from "@/components/Social/BrandNotificationSections";
import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, renderHook, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { AppBskyActorDefs, AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Navigation from "next/navigation";
import * as Catalog from "@/lib/blueskySocialClient";
import * as Client from "@/lib/blueskySocialDiscoveryClient";
import * as ExploreDiscovery from "@/lib/socialExploreDiscoveryClient";
import * as Interactive from "@/components/Social/InteractiveSocialPost";
import { SocialExplore } from "@/components/Social/SocialExplore";
import { SocialNotifications } from "@/components/Social/SocialNotifications";
import { useSocialExplore, useSocialNotifications } from "@/hooks/useSocialDiscovery";
import { SidebarProvider } from "@/components/ui/sidebar";

const alice = "did:plc:alice";
const bob = "did:plc:bob";
const safety = (did: string): ModerationOpts => ({ userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } });
const actor: AppBskyActorDefs.ProfileView = { did: "did:plc:other", handle: "other.test", displayName: "Other" };
const post = (key: string, author = actor): AppBskyFeedDefs.PostView => ({ uri: `at://did:plc:other/app.bsky.feed.post/${key}`, cid: "bafyreia", author: { ...author, $type: "app.bsky.actor.defs#profileViewBasic" }, record: { $type: "app.bsky.feed.post", text: key, createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z" });
const notification = (key: string, author = actor): Client.SocialNotification => ({ uri: `at://did:plc:other/app.bsky.feed.post/${key}`, cid: "bafyreia", author, reason: "reply", record: {}, isRead: false, indexedAt: "2026-10-10T00:00:00Z" });
const restores: (() => void)[] = [];
let viewer: string | null;
let oauthDid: string | null;
let queryClient: QueryClient;
const replaceRoute = mock(() => {});
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={queryClient}><SidebarProvider>{children}</SidebarProvider></QueryClientProvider>; }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; }
function restoreSpy<T extends { mockRestore(): void }>(spy: T) { restores.push(() => spy.mockRestore()); return spy; }
// Control only the dwell timers; React Query and Testing Library keep real timers.
function pageReadClock() {
  let now = 0;
  let nextId = -1;
  const scheduled = new Map<number, { due: number; callback: () => void }>();
  const originalTimeout = globalThis.setTimeout;
  const originalClear = globalThis.clearTimeout;
  const visibility = Object.getOwnPropertyDescriptor(document, "visibilityState");
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  restores.push(() => { if (visibility) Object.defineProperty(document, "visibilityState", visibility); else Reflect.deleteProperty(document, "visibilityState"); });
  globalThis.setTimeout = ((callback: () => void, delay?: number, ...args: unknown[]) => {
    if (delay !== 2_000) return originalTimeout(callback, delay, ...args);
    const id = nextId--; scheduled.set(id, { due: now + delay, callback });
    return id;
  }) as typeof setTimeout;
  globalThis.clearTimeout = (id => {
    if (!scheduled.delete(Number(id))) originalClear(id as Parameters<typeof clearTimeout>[0]);
  }) as typeof clearTimeout;
  restores.push(() => { globalThis.setTimeout = originalTimeout; globalThis.clearTimeout = originalClear; });
  return {
    get pending() { return scheduled.size; },
    async advance(milliseconds: number) {
      now += milliseconds;
      await act(async () => {
        for (const [id, timer] of scheduled) {
          if (timer.due <= now) { scheduled.delete(id); timer.callback(); }
        }
      });
    },
  };
}
beforeEach(() => {
  replaceRoute.mockClear();
  restoreSpy(spyOn(ExploreDiscovery, "getSocialTrendingTopics").mockResolvedValue({ topics: [{ topic: "Trending Science", link: "/search?q=science" }], suggested: [] }));
  restoreSpy(spyOn(ExploreDiscovery, "getSocialRecommendedFeeds").mockResolvedValue([]));
  restoreSpy(spyOn(Navigation, "useRouter").mockReturnValue({ replace: replaceRoute, push: () => {} } as unknown as ReturnType<typeof Navigation.useRouter>));
  restoreSpy(spyOn(Navigation, "useSearchParams").mockReturnValue(new URLSearchParams() as ReturnType<typeof Navigation.useSearchParams>));
  viewer = alice; oauthDid = alice;
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const media = Object.getOwnPropertyDescriptor(window, "matchMedia");
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
  restores.push(() => { if (media) Object.defineProperty(window, "matchMedia", media); else Reflect.deleteProperty(window, "matchMedia"); });
  restoreSpy(spyOn(Auth, "useAuth").mockImplementation(() => ({ session: viewer ? { did: viewer } : null, getOAuthSession: () => oauthDid ? { did: oauthDid } as OAuthSession : null, oauthSessionReloadSeq: 0, signIn: async () => {} } as unknown as ReturnType<typeof Auth.useAuth>)));
  restoreSpy(spyOn(Catalog, "getBlueskySocialCatalog").mockImplementation(async session => ({ feeds: [], moderation: safety(session.did) })));
  restoreSpy(spyOn(Interactive, "InteractiveSocialPost").mockImplementation(({ item }) => <article>{(item.post.record as { text: string }).text}</article>));
});
afterEach(() => { cleanup(); queryClient.clear(); restores.splice(0).reverse().forEach(restore => restore()); });

it("restores Explore search and type from its return URL and persists submitted changes", async () => {
  restoreSpy(spyOn(Navigation, "useSearchParams").mockReturnValue(new URLSearchParams({ q: "trees", type: "people" }) as ReturnType<typeof Navigation.useSearchParams>));
  const fetch = spyOn(Client, "getSocialExplorePage").mockResolvedValue({ actors: [actor], posts: [] });
  restoreSpy(fetch);
  render(<SocialExplore />, { wrapper: Wrapper });
  await screen.findByText("Other");
  expect((screen.getByRole("textbox", { name: "Search Bluesky" }) as HTMLInputElement).value).toBe("trees");
  expect(fetch.mock.calls[0]![0]).toMatchObject({ query: "trees", kind: "people" });
  fireEvent.change(screen.getByRole("textbox", { name: "Search Bluesky" }), { target: { value: "forest" } });
  fireEvent.click(screen.getByRole("button", { name: "Search" }));
  expect(replaceRoute).toHaveBeenCalledWith("/social/explore?q=forest&type=people", { scroll: false });
});

it("Explore performs real suggestions, submitted post search, people search and pagination", async () => {
  const fetch = spyOn(Client, "getSocialExplorePage").mockImplementation(async args => !args.query ? { actors: [actor], posts: [] } : args.kind === "people" ? { actors: [{ ...actor, displayName: "Search Person" }], posts: [] } : { actors: [], posts: [post(args.cursor ? "second" : "first")], cursor: args.cursor ? undefined : "next" });
  restoreSpy(fetch);
  render(<SocialExplore />, { wrapper: Wrapper });
  await screen.findByText("Suggested People");
  expect(await screen.findByText("Other")).toBeTruthy();
  fireEvent.change(screen.getByRole("textbox", { name: "Search Bluesky" }), { target: { value: "science" } });
  fireEvent.click(screen.getByRole("button", { name: "Search" }));
  await screen.findByText("first");
  expect(fetch.mock.calls.some(call => call[0].query === "science" && call[0].kind === "posts")).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Load More" }));
  await screen.findByText("second");
  fireEvent.click(screen.getByRole("button", { name: "People" }));
  await screen.findByText("Search Person");
  expect(screen.queryByText("first")).toBeNull();
});

it("Explore filters blocked posts and actors and fails closed when moderation refresh fails", async () => {
  const blocked = { ...actor, displayName: "Blocked Person", viewer: { blocking: "at://did:plc:alice/app.bsky.graph.block/one" } };
  const catalog = spyOn(Catalog, "getBlueskySocialCatalog").mockResolvedValue({ feeds: [], moderation: safety(alice) }); restoreSpy(catalog);
  const fetch = spyOn(Client, "getSocialExplorePage").mockResolvedValue({ actors: [blocked], posts: [post("secret", blocked)] }); restoreSpy(fetch);
  render(<SocialExplore />, { wrapper: Wrapper });
  await screen.findByText("No suggestions to show right now.");
  expect(screen.queryByText("Blocked Person")).toBeNull(); expect(screen.queryByText("secret")).toBeNull();
  catalog.mockRejectedValue(new Error("Your moderation settings could not be loaded. Please retry."));
  await act(async () => { await queryClient.invalidateQueries({ queryKey: ["blueskySocial", alice, "catalog"] }); });
  expect(await screen.findByText("Explore Unavailable")).toBeTruthy();
  expect(screen.getByRole("region", { name: "Suggested People" })).toBeTruthy();
});

it("Notifications shows unread rows and hydrated interactive posts, then marks seen explicitly", async () => {
  let marked = false;
  const fetch = spyOn(Client, "getSocialNotificationsPage").mockImplementation(async () => ({ notifications: [{ ...notification("reply-post"), isRead: marked }], posts: [post("reply-post")] })); restoreSpy(fetch);
  const unread = spyOn(Client, "getSocialNotificationUnread").mockImplementation(async () => marked ? 0 : 1); restoreSpy(unread);
  const seen = spyOn(Client, "markSocialNotificationsSeen").mockImplementation(async () => { marked = true; }); restoreSpy(seen);
  render(<SocialNotifications />, { wrapper: Wrapper });
  await screen.findByText("reply-post");
  expect(screen.getByText("Replied to Your Post")).toBeTruthy();
  expect(screen.getByText("Unread")).toBeTruthy();
  expect(seen).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Mark All As Read" }));
  await waitFor(() => expect(seen).toHaveBeenCalledTimes(1));
  expect(seen.mock.calls[0][0].did).toBe(alice);
  expect(Number.isFinite(Date.parse(seen.mock.calls[0][1]))).toBe(true);
  await screen.findByText("0 Unread");
  expect(screen.queryByText("Unread")).toBeNull();
});

it("Notifications hides blocked authors and posts and never requests content before moderation", async () => {
  const pending = deferred<Catalog.BlueskySocialCatalog>();
  restoreSpy(spyOn(Catalog, "getBlueskySocialCatalog").mockReturnValue(pending.promise));
  const blocked = { ...actor, viewer: { muted: true } };
  const fetch = spyOn(Client, "getSocialNotificationsPage").mockResolvedValue({ notifications: [notification("blocked", blocked), notification("hidden-post")], posts: [post("blocked", blocked), post("hidden-post", blocked)] }); restoreSpy(fetch);
  restoreSpy(spyOn(Client, "getSocialNotificationUnread").mockResolvedValue(2));
  render(<SocialNotifications />, { wrapper: Wrapper });
  expect(fetch).not.toHaveBeenCalled();
  expect(screen.getByRole("button", { name: "Mark All As Read" }).hasAttribute("disabled")).toBe(true);
  await act(async () => pending.resolve({ feeds: [], moderation: safety(alice) }));
  await screen.findByText("No notifications to show.");
  expect(screen.queryByText("blocked")).toBeNull();
  expect(screen.queryByText("hidden-post")).toBeNull();
});

it("discovery query changes cancel previous work, isolate accounts, and stop repeated cursors", async () => {
  let signal: AbortSignal | undefined;
  const fetch = spyOn(Client, "getSocialExplorePage").mockImplementation(args => {
    if (args.query === "slow") { signal = args.signal; return new Promise((_resolve, reject) => args.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true })); }
    return Promise.resolve({ actors: [], posts: [post(`${args.session.did}-${args.query}`)], cursor: "loop" });
  }); restoreSpy(fetch);
  const { result, rerender } = renderHook(({ query, moderation }) => useSocialExplore(query, "posts", moderation), { initialProps: { query: "slow", moderation: safety(alice) }, wrapper: Wrapper });
  await waitFor(() => expect(signal).toBeInstanceOf(AbortSignal));
  rerender({ query: "new", moderation: safety(alice) });
  await waitFor(() => expect(signal?.aborted).toBe(true));
  await waitFor(() => expect(result.current.isSuccess).toBe(true));
  expect(result.current.hasNextPage).toBe(true);
  expect(result.current.data?.pages).toHaveLength(1);
  await act(async () => { await result.current.fetchNextPage(); });
  await waitFor(() => expect(result.current.hasNextPage).toBe(false));
  viewer = bob; oauthDid = bob;
  rerender({ query: "new", moderation: safety(bob) });
  expect(result.current.data).toBeUndefined();
  await waitFor(() => expect(result.current.isSuccess).toBe(true));
  expect(result.current.data?.pages[0].posts[0].uri).toContain(bob);
});

it("notification hooks reject changed OAuth identity and remain disabled without safety settings", async () => {
  const fetch = spyOn(Client, "getSocialNotificationsPage").mockResolvedValue({ notifications: [], posts: [] }); restoreSpy(fetch);
  const { result, rerender } = renderHook(({ moderation }) => useSocialNotifications(moderation), { initialProps: { moderation: undefined as ModerationOpts | undefined }, wrapper: Wrapper });
  expect(fetch).not.toHaveBeenCalled();
  oauthDid = bob;
  rerender({ moderation: safety(alice) });
  await waitFor(() => expect(result.current.isError).toBe(true));
  expect(fetch).not.toHaveBeenCalled();
  expect((result.current.error as Error).message).toContain("account changed");
});

it("unsupported Explore service shows an error instead of a successful empty state", async () => {
  restoreSpy(spyOn(Client, "getSocialExplorePage").mockRejectedValue({ error: "MethodNotImplemented", status: 501 }));
  render(<SocialExplore />, { wrapper: Wrapper });
  expect(await screen.findByText("Explore is not supported by this server.")).toBeTruthy();
  expect(screen.queryByText("No suggestions to show right now.")).toBeNull();
  expect(screen.getByRole("button", { name: "Retry" })).toBeTruthy();
});

it("notifications paginate, deduplicate overlap and stop rendering after moderation failure", async () => {
  const catalog = spyOn(Catalog, "getBlueskySocialCatalog").mockResolvedValue({ feeds: [], moderation: safety(alice) }); restoreSpy(catalog);
  const fetch = spyOn(Client, "getSocialNotificationsPage").mockImplementation(async args => ({ notifications: args.cursor ? [notification("one"), notification("two")] : [notification("one")], posts: args.cursor ? [post("one"), post("two")] : [post("one")], cursor: args.cursor ? undefined : "next" })); restoreSpy(fetch);
  restoreSpy(spyOn(Client, "getSocialNotificationUnread").mockResolvedValue(2));
  render(<SocialNotifications />, { wrapper: Wrapper });
  await screen.findByText("one");
  fireEvent.click(screen.getByRole("button", { name: "Load More" }));
  await screen.findByText("two");
  expect(screen.getAllByText("one")).toHaveLength(1);
  catalog.mockRejectedValue(new Error("Your moderation settings could not be loaded. Please retry."));
  fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Notifications Unavailable");
  expect(screen.queryByText("one")).toBeNull();
  expect(screen.queryByText("two")).toBeNull();
  expect(screen.getByRole("button", { name: "Mark All As Read" }).hasAttribute("disabled")).toBe(true);
});

it("notification mark-seen failure retains unread rows and allows another attempt", async () => {
  restoreSpy(spyOn(Client, "getSocialNotificationsPage").mockResolvedValue({ notifications: [notification("unread-post")], posts: [post("unread-post")] }));
  restoreSpy(spyOn(Client, "getSocialNotificationUnread").mockResolvedValue(1));
  const mark = spyOn(Client, "markSocialNotificationsSeen").mockRejectedValueOnce(new Error("Network failure")).mockResolvedValue(undefined); restoreSpy(mark);
  render(<SocialNotifications />, { wrapper: Wrapper });
  await screen.findByText("unread-post");
  fireEvent.click(screen.getByRole("button", { name: "Mark All As Read" }));
  await screen.findByText("Notifications could not be loaded. Please retry.");
  expect(screen.getByText("Unread")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Mark All As Read" }));
  await waitFor(() => expect(mark).toHaveBeenCalledTimes(2));
});


it("Trending Topics updates Posts search and the shareable Explore URL", async () => {
  const fetch = spyOn(Client, "getSocialExplorePage").mockResolvedValue({ actors: [], posts: [] }); restoreSpy(fetch);
  render(<SocialExplore />, { wrapper: Wrapper });
  fireEvent.click(await screen.findByRole("button", { name: "Trending Science" }));
  await waitFor(() => expect(fetch.mock.calls.some(call => call[0].query === "science" && call[0].kind === "posts")).toBe(true));
  expect(replaceRoute).toHaveBeenCalledWith("/social/explore?q=science&type=posts", { scroll: false });
  expect((screen.getByRole("textbox", { name: "Search Bluesky" }) as HTMLInputElement).value).toBe("science");
  expect(screen.queryByText("Trending Topics")).toBeNull();
});

it("groups Explore search, trends, feeds and people into separate cards", async () => {
  restoreSpy(spyOn(Client, "getSocialExplorePage").mockResolvedValue({ actors: [actor], posts: [] }));
  render(<SocialExplore />, { wrapper: Wrapper });
  await screen.findByText("Other");
  for (const name of ["Search", "Trending Topics", "Recommended Feeds", "Suggested People"]) {
    const region = screen.getByRole("region", { name });
    expect(region.tagName).toBe("SECTION");
    expect(region.className).toContain("p-3");
    expect(region.parentElement?.tagName).toBe("DIV");
  }
});

it("keeps personal notifications available without rendering linked-brand controls when Tools is disabled", async () => {
  restoreSpy(spyOn(Tools, "toolsEnabled").mockReturnValue(false));
  restoreSpy(spyOn(Brands, "useBrandAccounts").mockReturnValue(["did:plc:brand"]));
  const brands = spyOn(BrandNotifications, "BrandNotificationSections").mockReturnValue(<p>Brand Tools</p>); restoreSpy(brands);
  restoreSpy(spyOn(Client, "getSocialNotificationsPage").mockResolvedValue({ notifications: [], posts: [] }));
  restoreSpy(spyOn(Client, "getSocialNotificationUnread").mockResolvedValue(0));
  render(<SocialNotifications />, { wrapper: Wrapper });
  await screen.findByText("No notifications to show.");
  expect(brands).not.toHaveBeenCalled();
  expect(screen.queryByText("Brand Tools")).toBeNull();
});

it("automatically marks loaded notifications seen only after two visible seconds at their loaded boundary", async () => {
  const clock = pageReadClock();
  let marked = false;
  const loaded = { ...notification("delayed-post"), indexedAt: "2026-10-10T12:34:56Z" };
  restoreSpy(spyOn(Client, "getSocialNotificationsPage").mockImplementation(async () => ({ notifications: [{ ...loaded, isRead: marked }], posts: [post("delayed-post")] })));
  restoreSpy(spyOn(Client, "getSocialNotificationUnread").mockImplementation(async () => marked ? 0 : 1));
  const seen = restoreSpy(spyOn(Client, "markSocialNotificationsSeen").mockImplementation(async () => { marked = true; }));
  render(<SocialNotifications />, { wrapper: Wrapper });
  await screen.findByText("delayed-post");
  await waitFor(() => expect(clock.pending).toBe(1));
  await clock.advance(1_999);
  expect(seen).not.toHaveBeenCalled();
  expect(screen.getByText("Unread")).toBeTruthy();
  await clock.advance(1);
  await waitFor(() => expect(seen).toHaveBeenCalledTimes(1));
  expect(seen.mock.calls[0]![0].did).toBe(alice);
  expect(seen.mock.calls[0]![1]).toBe(new Date(loaded.indexedAt).toISOString());
  await screen.findByText("0 Unread");
  await clock.advance(2_000);
  expect(seen).toHaveBeenCalledTimes(1);
});

it("retains notification unread state when automatic upstream seen fails", async () => {
  const clock = pageReadClock();
  restoreSpy(spyOn(Client, "getSocialNotificationsPage").mockResolvedValue({ notifications: [notification("auto-failure")], posts: [post("auto-failure")] }));
  restoreSpy(spyOn(Client, "getSocialNotificationUnread").mockResolvedValue(1));
  const seen = restoreSpy(spyOn(Client, "markSocialNotificationsSeen").mockRejectedValue(new Error("Network failure")));
  render(<SocialNotifications />, { wrapper: Wrapper });
  await screen.findByText("auto-failure");
  await waitFor(() => expect(clock.pending).toBe(1));
  await clock.advance(2_000);
  await screen.findByText("Notifications could not be loaded. Please retry.");
  expect(screen.getByText("Unread")).toBeTruthy();
  expect(screen.getByText("1 Unread")).toBeTruthy();
  await clock.advance(2_000);
  expect(seen).toHaveBeenCalledTimes(1);
});

it("cancels notification auto-read when leaving or switching away from the loaded account", async () => {
  const clock = pageReadClock();
  restoreSpy(spyOn(Client, "getSocialNotificationsPage").mockResolvedValue({ notifications: [notification("leaving-post")], posts: [post("leaving-post")] }));
  restoreSpy(spyOn(Client, "getSocialNotificationUnread").mockResolvedValue(1));
  const seen = restoreSpy(spyOn(Client, "markSocialNotificationsSeen").mockResolvedValue(undefined));
  const view = render(<SocialNotifications />, { wrapper: Wrapper });
  await screen.findByText("leaving-post");
  await waitFor(() => expect(clock.pending).toBe(1));
  await clock.advance(1_000);
  viewer = null; oauthDid = null;
  view.rerender(<SocialNotifications />);
  expect(clock.pending).toBe(0);
  await clock.advance(2_000);
  expect(seen).not.toHaveBeenCalled();
  view.unmount();
});
