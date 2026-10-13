import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Navigation from "next/navigation";

import * as Auth from "@/hooks/useAuth";
import * as Client from "@/lib/blueskySocialClient";
import SocialPage from "@/app/social/page";
import { SidebarProvider } from "@/components/ui/sidebar";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { requestSocialHomeRefresh } from "@/lib/socialHomeRefresh";

const did = "did:plc:viewer";
const safety: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
function item(key: string, text: string): AppBskyFeedDefs.FeedViewPost {
  return { post: { uri: `at://did:plc:other/app.bsky.feed.post/${key}`, cid: "bafyreia", author: { did: "did:plc:other", handle: "other.test" }, record: { $type: "app.bsky.feed.post", text, createdAt: "2026-10-09T10:00:00.000Z" }, indexedAt: "2026-10-09T10:00:00.000Z" } };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(complete => { resolve = complete; });
  return { promise, resolve };
}
const signIn = mock(async (_input: string) => { void _input; });
const restores: (() => void)[] = [];
let queryClient: QueryClient;
let params: URLSearchParams;
const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => { Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) }); });
afterAll(() => {
  if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia);
  else Reflect.deleteProperty(window, "matchMedia");
});
beforeEach(() => {
  params = new URLSearchParams();
  signIn.mockClear();
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }) as unknown as OAuthSession, oauthSessionReloadSeq: 0, signIn } as unknown as ReturnType<typeof Auth.useAuth>);
  const search = spyOn(Navigation, "useSearchParams").mockImplementation(() => params as ReturnType<typeof Navigation.useSearchParams>);
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ push: mock(() => {}), replace: mock(() => {}) } as unknown as ReturnType<typeof Navigation.useRouter>);
  const path = spyOn(Navigation, "usePathname").mockReturnValue("/social");
  restores.push(() => auth.mockRestore(), () => search.mockRestore(), () => router.mockRestore(), () => path.mockRestore());
});
afterEach(() => {
  cleanup();
  queryClient.clear();
  restores.splice(0).reverse().forEach(restore => restore());
});
async function show() {
  await act(async () => { render(<QueryClientProvider client={queryClient}><SidebarProvider><SocialPage /></SidebarProvider></QueryClientProvider>); });
}
function serveCatalog(value: Client.BlueskySocialCatalog = { feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: safety }) {
  const fetch = spyOn(Client, "getBlueskySocialCatalog").mockResolvedValue(value);
  restores.push(() => fetch.mockRestore());
  return fetch;
}
function servePage(value: Client.BlueskySocialPage = { feed: [] }) {
  const fetch = spyOn(Client, "getBlueskySocialPage").mockResolvedValue(value);
  restores.push(() => fetch.mockRestore());
  return fetch;
}

describe("Social timeline page", () => {
  it("returns to the top and reloads only the first page on Home refresh", async () => {
    serveCatalog();
    const posts = servePage({ feed: [item("one", "First page")], cursor: "older" });
    posts.mockImplementation(async args => args.cursor
      ? { feed: [item("two", "Older page")] }
      : { feed: [item("one", "First page")], cursor: "older" });
    await show();
    await screen.findByText("First page");
    fireEvent.click(screen.getByRole("button", { name: "Load More" }));
    await screen.findByText("Older page");
    const scroll = screen.getByText("First page").closest('[data-analytics-subject]')!.parentElement!.closest('.overflow-y-auto') as HTMLElement;
    scroll.scrollTop = 800;
    await act(async () => { requestSocialHomeRefresh(); });
    await waitFor(() => expect(posts).toHaveBeenCalledTimes(3));
    await waitFor(() => expect(screen.queryByText("Older page")).toBeNull());
    expect(scroll.scrollTop).toBe(0);
    expect(posts.mock.calls.map(([args]) => args.cursor)).toEqual([undefined, "older", undefined]);
  });
  it("rejects invalid and conflicting feed parameters without fetching posts", async () => {
    params = new URLSearchParams("feed=https://example.com/not-a-feed&list=at://did:plc:other/app.bsky.graph.list/team");
    serveCatalog().mockReturnValue(deferred<Client.BlueskySocialCatalog>().promise);
    const posts = servePage();
    await show();
    expect(screen.getByRole("alert").textContent).toContain("Choose one social feed at a time.");
    expect(screen.getByRole("button", { name: "Refresh Social Feed" }).hasAttribute("disabled")).toBe(true);
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
    expect(posts).not.toHaveBeenCalled();
  });

  it("waits for moderation settings before fetching or showing posts", async () => {
    const pending = deferred<Client.BlueskySocialCatalog>();
    const catalog = spyOn(Client, "getBlueskySocialCatalog").mockReturnValue(pending.promise);
    restores.push(() => catalog.mockRestore());
    const posts = servePage({ feed: [item("one", "Moderated first post")] });
    await show();
    expect(screen.getByRole("status", { name: "Loading Social Posts" })).toBeTruthy();
    expect(posts).not.toHaveBeenCalled();
    await act(async () => { pending.resolve({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: safety }); });
    await waitFor(() => expect(screen.getByText("Moderated first post")).toBeTruthy());
    expect(posts.mock.calls[0]?.[0].moderation).toBe(safety);
  });

  it("hides cached posts when moderation reload fails and offers retry", async () => {
    const catalog = serveCatalog();
    const posts = servePage({ feed: [item("one", "Previously visible post")] });
    await show();
    await waitFor(() => expect(screen.getByText("Previously visible post")).toBeTruthy());
    catalog.mockRejectedValue(new Error("Your moderation settings could not be loaded. Please retry."));
    fireEvent.click(screen.getByRole("button", { name: "Refresh Social Feed" }));
    await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("moderation settings could not be loaded"));
    expect(screen.queryByText("Previously visible post")).toBeNull();
    expect(screen.getByRole("button", { name: "Retry" })).toBeTruthy();
    expect(posts).toHaveBeenCalledTimes(1);
  });

  it("applies hidden-post preferences and explains a filtered page", async () => {
    const hidden = item("hidden", "Hidden private content");
    serveCatalog({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: { ...safety, prefs: { ...safety.prefs, hiddenPosts: [hidden.post.uri] } } });
    servePage({ feed: [hidden] });
    await show();
    await waitFor(() => expect(screen.getByText("No Posts to Show")).toBeTruthy());
    expect(screen.queryByText("Hidden private content")).toBeNull();
    expect(screen.getByText("Posts on this page are hidden by your moderation settings.")).toBeTruthy();
  });

  it("loads the next page once and removes Load More on a repeated cursor", async () => {
    serveCatalog();
    const posts = spyOn(Client, "getBlueskySocialPage").mockImplementation(async args => ({ feed: [args.cursor ? item("two", "Second post") : item("one", "First post")], cursor: "repeat" }));
    restores.push(() => posts.mockRestore());
    await show();
    await waitFor(() => expect(screen.getByText("First post")).toBeTruthy());
    fireEvent.click(screen.getByRole("button", { name: "Load More" }));
    await waitFor(() => expect(screen.getByText("Second post")).toBeTruthy());
    expect(screen.getByText("First post")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Load More" })).toBeNull();
    expect(posts.mock.calls.map(([args]) => args.cursor)).toEqual([undefined, "repeat"]);
  });

  it("returns to the same scroll position with cached paginated feed rows", async () => {
    serveCatalog();
    const posts = spyOn(Client, "getBlueskySocialPage").mockImplementation(async args => ({
      feed: [args.cursor ? item("return-two", "Return Second Page") : item("return-one", "Return First Page")],
      cursor: args.cursor ? undefined : "next-return-page",
    }));
    restores.push(() => posts.mockRestore());
    await show();
    await screen.findByText("Return First Page");
    fireEvent.click(screen.getByRole("button", { name: "Load More" }));
    const row = await screen.findByText("Return Second Page");
    const scrolling = row.closest(".overflow-y-auto") as HTMLElement;
    scrolling.scrollTop = 780;
    fireEvent.scroll(scrolling);
    fireEvent.click(row);
    expect(Navigation.useRouter().push).toHaveBeenCalled();
    cleanup();
    await show();
    const returned = await screen.findByText("Return Second Page");
    expect(returned.closest(".overflow-y-auto")?.scrollTop).toBe(780);
    expect(screen.getByText("Return First Page")).toBeTruthy();
    expect(posts).toHaveBeenCalledTimes(2);
  });

  it("refreshes safety settings before invalidating posts and reflects updated preferences", async () => {
    const oldPost = item("old", "Old feed post");
    const refreshed = deferred<Client.BlueskySocialCatalog>();
    const catalog = serveCatalog();
    catalog.mockResolvedValueOnce({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: safety }).mockReturnValueOnce(refreshed.promise);
    const posts = servePage({ feed: [oldPost] });
    posts.mockResolvedValueOnce({ feed: [oldPost] }).mockResolvedValueOnce({ feed: [item("new", "Refreshed feed post")] });
    await show();
    await waitFor(() => expect(screen.getByText("Old feed post")).toBeTruthy());
    fireEvent.click(screen.getByRole("button", { name: "Refresh Social Feed" }));
    await waitFor(() => expect(catalog).toHaveBeenCalledTimes(2));
    expect(posts).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Refresh Social Feed" }).hasAttribute("disabled")).toBe(true);
    await act(async () => { refreshed.resolve({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: { ...safety, prefs: { ...safety.prefs, hiddenPosts: [oldPost.post.uri] } } }); });
    await waitFor(() => expect(screen.getByText("Refreshed feed post")).toBeTruthy());
    expect(screen.queryByText("Old feed post")).toBeNull();
    expect(posts).toHaveBeenCalledTimes(2);
  });

  it("offers account reauthorization when the OAuth grant lacks scope", async () => {
    const catalog = spyOn(Client, "getBlueskySocialCatalog").mockRejectedValue(new Error(SCOPE_RECOVERY_MESSAGE));
    restores.push(() => catalog.mockRestore());
    const posts = servePage();
    await show();
    await waitFor(() => expect(screen.getByRole("button", { name: "Log In Again" })).toBeTruthy());
    expect(screen.getByRole("alert").textContent).toContain(SCOPE_RECOVERY_MESSAGE);
    fireEvent.click(screen.getByRole("button", { name: "Log In Again" }));
    expect(signIn).toHaveBeenCalledWith(did);
    expect(posts).not.toHaveBeenCalled();
  });
});
