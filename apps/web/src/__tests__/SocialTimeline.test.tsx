import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, renderHook, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider, dehydrate } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { PersistQueryClientProvider } from "@tanstack/react-query-persist-client";
import { prepareSocialQueryPersistence, shouldPersistSocialQuery } from "@/lib/socialQueryPersist";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Navigation from "next/navigation";

import * as Auth from "@/hooks/useAuth";
import * as Client from "@/lib/blueskySocialClient";
import SocialPage from "@/app/social/page";
import { useBlueskySocialTimeline } from "@/hooks/useBlueskySocialTimeline";
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
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((complete, fail) => { resolve = complete; reject = fail; });
  return { promise, resolve, reject };
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
  const oauth = { did } as unknown as OAuthSession;
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => oauth, oauthSessionReloadSeq: 0, signIn } as unknown as ReturnType<typeof Auth.useAuth>);
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
  let view!: ReturnType<typeof render>;
  await act(async () => { view = render(<QueryClientProvider client={queryClient}><SidebarProvider><SocialPage /></SidebarProvider></QueryClientProvider>); });
  return view;
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
  it("restores unsorted persisted labeler rows without a skeleton and preserves row DOM across equivalent reorder", async () => {
    const old = item("cached", "Cached post on reload");
    const persistedSafety = { ...safety, prefs: { ...safety.prefs, labelers: [{ did: "did:plc:z", labels: {} }, { did: "did:plc:a", labels: {} }] } };
    const freshSafety = { ...persistedSafety, prefs: { ...persistedSafety.prefs, labelers: [...persistedSafety.prefs.labelers].reverse() } };
    const catalogKey = ["blueskySocial", did, "catalog", "cache-v1"];
    const timelineKey = ["blueskySocial", did, "timeline", "cache-v1", "following", "", ["did:plc:z", "did:plc:a"]];
    const source = new QueryClient();
    source.setQueryData(catalogKey, { feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: persistedSafety });
    source.setQueryData(timelineKey, { pages: [{ feed: [old] }], pageParams: [undefined] });
    const snapshot = prepareSocialQueryPersistence({ timestamp: Date.now(), buster: "", clientState: dehydrate(source, { shouldDehydrateQuery: shouldPersistSocialQuery }) });
    source.clear();
    const restored = deferred<typeof snapshot>();
    const freshCatalog = deferred<Client.BlueskySocialCatalog>();
    serveCatalog().mockReturnValue(freshCatalog.promise);
    const freshPage = deferred<Client.BlueskySocialPage>();
    const posts = servePage().mockReturnValue(freshPage.promise);
    await act(async () => { render(<PersistQueryClientProvider client={queryClient} persistOptions={{ persister: { restoreClient: () => restored.promise, persistClient: async () => {}, removeClient: async () => {} } }}><SidebarProvider><SocialPage /></SidebarProvider></PersistQueryClientProvider>); });
    expect(posts).not.toHaveBeenCalled();
    await act(async () => { restored.resolve(structuredClone(snapshot)); });
    await screen.findByText("Cached post on reload");
    await waitFor(() => expect(posts).toHaveBeenCalledTimes(1));
    expect(screen.queryByRole("status", { name: "Loading Social Posts" })).toBeNull();
    const row = screen.getByText("Cached post on reload").closest("[data-analytics-subject]");
    expect(row).not.toBeNull();
    await act(async () => {
      freshCatalog.resolve({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: freshSafety });
      freshPage.resolve({ feed: [{ ...old, post: { ...old.post, likeCount: 5 } }, item("new", "New post from background refresh")] });
    });
    await screen.findByText("New post from background refresh");
    expect(screen.getByText("Cached post on reload").closest("[data-analytics-subject]")).toBe(row);
    expect(posts.mock.calls[0][0].cursor).toBeUndefined();
  });

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
  for (const trigger of ["manual", "Home"] as const) {
    it(`retains posts after a failed ${trigger} refresh and retries successfully`, async () => {
      serveCatalog();
      const posts = servePage({ feed: [item("retained", "Retained moderated post")] });
      await show();
      await screen.findByText("Retained moderated post");
      let reject!: (error: Error) => void;
      posts.mockReturnValueOnce(new Promise((_, fail) => { reject = fail; }));
      await act(async () => {
        if (trigger === "Home") requestSocialHomeRefresh();
        else fireEvent.click(screen.getByRole("button", { name: "Refresh Social Feed" }));
      });
      await waitFor(() => expect(posts).toHaveBeenCalledTimes(2));
      expect(screen.getByRole("button", { name: "Refresh Social Feed" }).hasAttribute("disabled")).toBe(true);
      await act(async () => { reject(new Error("Refresh network unavailable")); });
      await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("Social Refresh Unavailable"));
      expect(screen.getByText("Retained moderated post")).toBeTruthy();
      posts.mockResolvedValueOnce({ feed: [item("retry", "Recovered refreshed post")] });
      fireEvent.click(screen.getByRole("button", { name: "Retry" }));
      await screen.findByText("Recovered refreshed post");
      expect(screen.queryByRole("alert")).toBeNull();
      expect(screen.queryByText("Retained moderated post")).toBeNull();
      expect(posts.mock.calls.map(([args]) => args.cursor)).toEqual([undefined, undefined, undefined]);
    });
  }

  for (const context of ["account", "feed", "moderation", "feed round trip"] as const) {
    it(`ignores a refresh failure from a replaced ${context} context`, async () => {
      let oauth = { did } as unknown as OAuthSession;
      const auth = Auth.useAuth();
      spyOn(Auth, "useAuth").mockImplementation(() => ({ ...auth, session: { did: oauth.did }, getOAuthSession: () => oauth }));
      const posts = servePage({ feed: [item("account", "Original account post")] });
      let feed = Client.SOCIAL_FOLLOWING_FEED;
      let moderation = safety;
      const hook = renderHook(() => useBlueskySocialTimeline(feed, moderation), {
        wrapper: ({ children }) => <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>,
      });
      await waitFor(() => expect(hook.result.current.data?.pages[0].feed.length).toBe(1));
      let reject!: (error: Error) => void;
      let resolve!: (page: Client.BlueskySocialPage) => void;
      posts.mockReturnValueOnce(new Promise((complete, fail) => { resolve = complete; reject = fail; }));
      let refresh!: Promise<void>;
      act(() => { refresh = hook.result.current.refreshFirstPage(); });
      await waitFor(() => expect(posts).toHaveBeenCalledTimes(2));
      posts.mockReturnValue(deferred<Client.BlueskySocialPage>().promise);
      if (context === "account") oauth = { did: "did:plc:successor" } as unknown as OAuthSession;
      else if (context === "feed" || context === "feed round trip") feed = { kind: "list", name: "Other Feed", pinned: false, uri: "at://did:plc:other/app.bsky.graph.list/team" };
      else moderation = { ...safety, prefs: { ...safety.prefs, labelers: [{ did: "did:plc:labeler", labels: {} }] } };
      hook.rerender();
      if (context === "feed round trip") { feed = Client.SOCIAL_FOLLOWING_FEED; hook.rerender(); }
      await act(async () => {
        if (context === "feed round trip") resolve({ feed: [item("obsolete", "Obsolete refresh result")] });
        else reject(new Error("Previous account refresh failed"));
        await refresh;
      });
      expect(hook.result.current.refreshError).toBeUndefined();
      expect(hook.result.current.isRefreshing).toBe(false);
      if (context === "feed round trip") expect(hook.result.current.data?.pages[0].feed[0].post.uri).toBe(item("account", "").post.uri);
      else expect(hook.result.current.data).toBeUndefined();
    });
  }

  for (const trigger of ["manual", "Home"] as const) {
    it(`applies fresh labeler membership once on ${trigger} refresh and retries a failed request`, async () => {
      const catalog = serveCatalog();
      const posts = servePage({ feed: [item("before", "Before new labeler")] });
      await show();
      await screen.findByText("Before new labeler");
      const target = { ...safety, prefs: { ...safety.prefs, labelers: [{ did: "did:plc:new", labels: {} }] } };
      const pending = deferred<Client.BlueskySocialPage>();
      catalog.mockResolvedValue({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: target });
      posts.mockReturnValue(pending.promise);
      await act(async () => {
        if (trigger === "Home") requestSocialHomeRefresh();
        else fireEvent.click(screen.getByRole("button", { name: "Refresh Social Feed" }));
      });
      await waitFor(() => expect(posts).toHaveBeenCalledTimes(2));
      expect(posts.mock.calls[1][0].moderation).toEqual(target);
      expect(screen.queryByText("Before new labeler")).toBeNull();
      expect(screen.getByRole("status", { name: "Loading Social Posts" })).toBeTruthy();
      await act(async () => { pending.reject(new Error("New labeler page failed")); });
      await screen.findByRole("button", { name: "Retry" });
      posts.mockResolvedValue({ feed: [item("fresh-labels", "Covered by fresh labels")] });
      fireEvent.click(screen.getByRole("button", { name: "Retry" }));
      await screen.findByText("Covered by fresh labels");
      expect(posts).toHaveBeenCalledTimes(3);
      expect(screen.getByRole("button", { name: "Refresh Social Feed" }).hasAttribute("disabled")).toBe(false);
    });

    it(`refreshes posts at safety readiness on ${trigger} while optional metadata stalls, including a repeated refresh`, async () => {
      const catalog = serveCatalog();
      const posts = servePage({ feed: [item("initial", "Initial post before metadata stall")] });
      await show();
      await screen.findByText("Initial post before metadata stall");
      const metadata = deferred<Client.BlueskySocialCatalog>();
      let freshSafety = safety;
      catalog.mockImplementation((_oauth, _signal, options) => {
        const requestSafety = freshSafety;
        options?.onReady?.({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: requestSafety });
        return metadata.promise.then(result => ({ ...result, moderation: requestSafety }));
      });
      const newlyHidden = item("newly-hidden", "Post hidden by later preferences");
      posts.mockResolvedValue({ feed: [item("ready", "Post refreshed before metadata"), newlyHidden] });
      await act(async () => {
        if (trigger === "Home") requestSocialHomeRefresh();
        else fireEvent.click(screen.getByRole("button", { name: "Refresh Social Feed" }));
      });
      await screen.findByText("Post refreshed before metadata");
      await waitFor(() => expect(screen.getByRole("button", { name: "Refresh Social Feed" }).hasAttribute("disabled")).toBe(false));
      expect(posts).toHaveBeenCalledTimes(2);
      expect(screen.getByText("Post hidden by later preferences")).toBeTruthy();
      freshSafety = { ...safety, prefs: { ...safety.prefs, hiddenPosts: [newlyHidden.post.uri] } };
      posts.mockResolvedValue({ feed: [item("again", "Repeated refresh during metadata"), newlyHidden] });
      fireEvent.click(screen.getByRole("button", { name: "Refresh Social Feed" }));
      await screen.findByText("Repeated refresh during metadata");
      expect(screen.queryByText("Post hidden by later preferences")).toBeNull();
      expect(posts.mock.calls[2][0].moderation.prefs.hiddenPosts).toEqual([newlyHidden.post.uri]);
      expect(catalog).toHaveBeenCalledTimes(3);
      expect(posts).toHaveBeenCalledTimes(3);
      expect(screen.getByRole("button", { name: "Refresh Social Feed" }).hasAttribute("disabled")).toBe(false);
      await act(async () => { metadata.resolve({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: safety, metadataError: "Optional metadata offline" }); });
      await screen.findByText(/Saved Feed Details Unavailable/);
      expect(screen.queryByRole("alert")).toBeNull();
      expect(screen.getByText("Repeated refresh during metadata")).toBeTruthy();
      expect(posts).toHaveBeenCalledTimes(3);
    });
  }

  for (const context of ["account", "feed", "moderation", "same-membership policy", "session"] as const) {
    for (const phase of ["catalog", "page"] as const) {
      it(`ignores obsolete ${context} round trips while awaiting ${phase}`, async () => {
        let oauth = { did } as unknown as OAuthSession;
        let seq = 0;
        const originalOAuth = oauth;
        const auth = Auth.useAuth();
        const authSpy = spyOn(Auth, "useAuth").mockImplementation(() => ({ ...auth, session: { did: oauth.did }, getOAuthSession: () => oauth, oauthSessionReloadSeq: seq }));
        restores.push(() => authSpy.mockRestore());
        const posts = servePage({ feed: [item("current", "Current post")] });
        let feed = Client.SOCIAL_FOLLOWING_FEED;
        let moderation = safety;
        const hook = renderHook(() => useBlueskySocialTimeline(feed, moderation), { wrapper: ({ children }) => <QueryClientProvider client={queryClient}>{children}</QueryClientProvider> });
        await waitFor(() => expect(hook.result.current.data?.pages[0].feed.length).toBe(1));
        const settings = deferred<ModerationOpts>();
        const pending = deferred<Client.BlueskySocialPage>();
        posts.mockReturnValue(pending.promise);
        let refresh!: Promise<void>;
        act(() => { refresh = hook.result.current.refreshFirstPage(phase === "catalog" ? () => settings.promise : undefined); });
        if (phase === "page") await waitFor(() => expect(posts).toHaveBeenCalledTimes(2));
        await act(async () => {
          if (context === "account") oauth = { did: "did:plc:other-viewer" } as unknown as OAuthSession;
          else if (context === "session") seq++;
          else if (context === "feed") feed = { kind: "list", name: "Other", pinned: false, uri: "at://did:plc:other/app.bsky.graph.list/team" };
          else moderation = { ...safety, prefs: { ...safety.prefs, ...(context === "moderation" ? { labelers: [{ did: "did:plc:new", labels: {} }] } : { hiddenPosts: [item("current", "").post.uri] }) } };
          hook.rerender();
        });
        await act(async () => { oauth = originalOAuth; feed = Client.SOCIAL_FOLLOWING_FEED; moderation = safety; if (context === "session") seq++; hook.rerender(); });
        // A new gesture must not join the retired occurrence's pending request.
        posts.mockResolvedValueOnce({ feed: [item("successor", "Current refreshed post")] });
        await act(async () => { await hook.result.current.refreshFirstPage(); });
        await act(async () => {
          if (phase === "catalog") settings.resolve(safety);
          else pending.resolve({ feed: [item("obsolete", "Obsolete result")] });
          await refresh;
        });
        expect(hook.result.current.data?.pages[0].feed[0].post.uri).toBe(item("successor", "").post.uri);
        expect(hook.result.current.refreshError).toBeUndefined();
        expect(hook.result.current.isRefreshing).toBe(false);
      });
    }
  }

  for (const context of ["account", "feed", "moderation"] as const) {
    for (const phase of ["catalog", "page"] as const) {
      it(`keeps the rendered successor after a ${context} round trip during ${phase}`, async () => {
        let oauth = { did } as unknown as OAuthSession;
        const originalOAuth = oauth;
        const auth = Auth.useAuth();
        const authSpy = spyOn(Auth, "useAuth").mockImplementation(() => ({ ...auth, session: { did: oauth.did }, getOAuthSession: () => oauth }));
        restores.push(() => authSpy.mockRestore());
        const catalog = serveCatalog();
        const posts = servePage({ feed: [item("visible", "Visible current visit")] });
        const view = await show();
        await screen.findByText("Visible current visit");
        const pendingCatalog = deferred<Client.BlueskySocialCatalog>();
        const pendingPage = deferred<Client.BlueskySocialPage>();
        if (phase === "catalog") catalog.mockReturnValueOnce(pendingCatalog.promise);
        else posts.mockReturnValueOnce(pendingPage.promise);
        fireEvent.click(screen.getByRole("button", { name: "Refresh Social Feed" }));
        await waitFor(() => expect(phase === "catalog" ? catalog : posts).toHaveBeenCalledTimes(2));
        const tree = () => <QueryClientProvider client={queryClient}><SidebarProvider><SocialPage /></SidebarProvider></QueryClientProvider>;
        const catalogKey = ["blueskySocial", did, "catalog", "cache-v1"];
        await act(async () => {
          if (context === "account") oauth = { did: "did:plc:successor" } as unknown as OAuthSession;
          else if (context === "feed") params = new URLSearchParams("list=at://did:plc:other/app.bsky.graph.list/team");
          else queryClient.setQueryData(catalogKey, { feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: { ...safety, prefs: { ...safety.prefs, hiddenPosts: [item("visible", "").post.uri] } } });
          view.rerender(tree());
        });
        await act(async () => {
          oauth = originalOAuth;
          params = new URLSearchParams();
          if (context === "moderation") queryClient.setQueryData(catalogKey, { feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: safety });
          view.rerender(tree());
        });
        if (phase === "page") {
          posts.mockResolvedValueOnce({ feed: [item("successor", "Rendered successor refresh")] });
          fireEvent.click(screen.getByRole("button", { name: "Refresh Social Feed" }));
          await screen.findByText("Rendered successor refresh");
        }
        await act(async () => {
          if (phase === "catalog") pendingCatalog.resolve({ feeds: [Client.SOCIAL_FOLLOWING_FEED], moderation: safety });
          else pendingPage.resolve({ feed: [item("obsolete", "Obsolete rendered result")] });
        });
        expect(screen.queryByText("Obsolete rendered result")).toBeNull();
        expect(screen.queryByRole("alert")).toBeNull();
        if (phase === "page") expect(screen.getByText("Rendered successor refresh")).toBeTruthy();
        expect(screen.getByRole("button", { name: "Refresh Social Feed" }).hasAttribute("disabled")).toBe(false);
      });
    }
  }

  it("keeps post rows when reply decorations stall or fail", async () => {
    serveCatalog();
    servePage({ feed: [item("reply", "Reply before optional context")] });
    const pending = deferred<Client.BlueskySocialPage>();
    const hydrate = spyOn(Client, "hydrateBlueskySocialPage").mockReturnValue(pending.promise);
    restores.push(() => hydrate.mockRestore());
    await show();
    await screen.findByText("Reply before optional context");
    await waitFor(() => expect(hydrate).toHaveBeenCalledTimes(1));
    const row = screen.getByText("Reply before optional context").closest("[data-analytics-subject]");
    expect(screen.queryByRole("status", { name: "Loading Social Posts" })).toBeNull();
    await act(async () => { pending.reject(new Error("Optional thread unavailable")); });
    expect(screen.getByText("Reply before optional context").closest("[data-analytics-subject]")).toBe(row);
    expect(screen.queryByRole("alert")).toBeNull();
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

  it("retains posts under cached moderation when its refresh fails and offers retry", async () => {
    const catalog = serveCatalog();
    const posts = servePage({ feed: [item("one", "Previously visible post")] });
    await show();
    await waitFor(() => expect(screen.getByText("Previously visible post")).toBeTruthy());
    catalog.mockRejectedValue(new Error("Your moderation settings could not be loaded. Please retry."));
    fireEvent.click(screen.getByRole("button", { name: "Refresh Social Feed" }));
    await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("moderation settings could not be loaded"));
    expect(screen.getByText("Previously visible post")).toBeTruthy();
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
