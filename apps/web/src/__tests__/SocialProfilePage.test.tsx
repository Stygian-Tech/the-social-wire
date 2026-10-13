import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ModerationOpts } from "@atproto/api";
import * as Navigation from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import * as Profile from "@/hooks/useBlueskyProfile";
import * as Timeline from "@/hooks/useBlueskyProfileTimeline";
import * as Atproto from "@/lib/atprotoClient";
import { SidebarProvider } from "@/components/ui/sidebar";
import ProfilePage from "@/app/social/profile/page";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

const did = "did:plc:viewer";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const post = { uri: "at://did:plc:other/app.bsky.feed.post/test", cid: "bafyreia", author: { did: "did:plc:other", handle: "other.test" }, record: { $type: "app.bsky.feed.post", text: "Selected Post", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z" };
const push = mock(() => {});
const replace = mock(() => {});
let params: URLSearchParams;
let catalogError: Error | undefined;
let profileValue = { did: post.author.did, handle: "other.test", displayName: "Other Person", description: "A profile biography", postsCount: 8, viewer: {} };
const restores: (() => void)[] = [];
let cache: QueryClient;
beforeEach(() => {
  const location = window.location.href;
  const historyState = window.history.state;
  restores.push(() => window.history.replaceState(historyState, "", location));
  const media = Object.getOwnPropertyDescriptor(window, "matchMedia");
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
  restores.push(() => { if (media) Object.defineProperty(window, "matchMedia", media); else Reflect.deleteProperty(window, "matchMedia"); });
  for (const [name, value] of Object.entries({ HTMLElement: window.HTMLElement, HTMLInputElement: window.HTMLInputElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, DOMRect: window.DOMRect, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); });
  }
  params = new URLSearchParams({ actor: post.author.did, returnTo: "/social?feed=original" });
  catalogError = undefined; push.mockClear(); replace.mockClear();
  profileValue = { did: post.author.did, handle: "other.test", displayName: "Other Person", description: "A profile biography", postsCount: 8, viewer: {} };
  cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ push, replace } as unknown as ReturnType<typeof Navigation.useRouter>);
  const path = spyOn(Navigation, "usePathname").mockReturnValue("/social/profile");
  const search = spyOn(Navigation, "useSearchParams").mockImplementation(() => params as ReturnType<typeof Navigation.useSearchParams>);
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }), oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
  const catalog = spyOn(Catalog, "useBlueskySocialCatalog").mockImplementation(() => ({ data: { feeds: [], moderation }, isError: !!catalogError, error: catalogError, refetch: mock(async () => undefined) } as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>));
  const profile = spyOn(Profile, "useBlueskyProfile").mockImplementation(() => ({ data: profileValue, isError: false, isPending: false, refetch: mock(async () => undefined) } as unknown as ReturnType<typeof Profile.useBlueskyProfile>));
  const timeline = spyOn(Timeline, "useBlueskyProfileTimeline").mockReturnValue({ data: { pages: [{ feed: [] }] }, isError: false, isPending: false, hasNextPage: false } as unknown as ReturnType<typeof Timeline.useBlueskyProfileTimeline>);
  restores.push(() => profile.mockRestore(), () => timeline.mockRestore());
  restores.push(() => router.mockRestore(), () => path.mockRestore(), () => search.mockRestore(), () => auth.mockRestore(), () => catalog.mockRestore());
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function show() { return render(<QueryClientProvider client={cache}><SidebarProvider><ProfilePage /></SidebarProvider></QueryClientProvider>); }

describe("other-user profile page", () => {
  it("reuses profile identity and content tabs while keeping private likes and own controls separate", async () => {
    show();
    expect(screen.getByRole("heading", { name: "Other Person" })).toBeTruthy();
    expect(screen.getByText("A profile biography")).toBeTruthy();
    for (const name of ["Posts", "Replies", "Media", "Likes"]) expect(screen.getByRole("button", { name })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Publications" }) === null).toBe(true);
    expect(screen.queryByRole("button", { name: /Edit Profile|Settings/ }) === null).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Likes" }));
    expect(screen.getByText("Likes are private. Only your own likes are available.")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Back" }));
    expect(replace).toHaveBeenCalledWith("/social?feed=original");
  });
  it("does not expose a blocked profile identity or its content tabs", () => {
    profileValue.viewer = { blocking: "at://did:plc:viewer/app.bsky.graph.block/one" };
    show();
    expect(screen.getByText("Profile withheld by your moderation settings.")).toBeTruthy();
    expect(screen.queryByText("Other Person") === null).toBe(true);
    expect(screen.queryByRole("button", { name: "Posts" }) === null).toBe(true);
    expect(screen.queryByRole("button", { name: /Follow/ })).toBeNull();
  });
  it("follows from the full viewer and shares Following state with profile previews", async () => {
    const follow = mock(async () => ({ uri: `at://${did}/app.bsky.graph.follow/one`, cid: "cid" }));
    const agent = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ follow } as unknown as ReturnType<typeof Atproto.createOAuthAgent>);
    restores.push(() => agent.mockRestore());
    show();
    fireEvent.click(screen.getByRole("button", { name: "Follow @other.test" }));
    await screen.findByRole("button", { name: "Following @other.test" });
    expect(follow).toHaveBeenCalledTimes(1);
    expect(follow).toHaveBeenCalledWith(post.author.did);
    expect(cache.getQueryData<string>(["blueskySocial", did, "following", 0, post.author.did])).toBe(`at://${did}/app.bsky.graph.follow/one`);
  });
  it("shows an existing follow and omits following your own profile", () => {
    profileValue.viewer = { following: `at://${did}/app.bsky.graph.follow/existing` };
    const view = show();
    expect(screen.getByRole("button", { name: "Following @other.test" }).hasAttribute("disabled")).toBe(true);
    view.unmount();
    profileValue.did = did;
    params = new URLSearchParams({ actor: did, returnTo: "/social" });
    show();
    expect(screen.queryByRole("button", { name: /Follow/ })).toBeNull();
  });
  it("fails closed when the viewer moderation catalog fails", async () => {
    catalogError = new Error(SCOPE_RECOVERY_MESSAGE);
    show();
    await waitFor(() => expect(screen.getByRole("button", { name: "Log In Again" })).toBeTruthy());
    expect(screen.queryByText("Other Person") === null).toBe(true);
  });
  it("validates internal profile destinations and rejects external Back destinations", () => {
    expect(socialProfilePageHref("did:plc:other", "/social/explore?q=trees&type=people")).toContain("returnTo=%2Fsocial%2Fexplore%3Fq%3Dtrees%26type%3Dpeople");
    expect(() => socialProfilePageHref("javascript:alert(1)")).toThrow("invalid");
    params = new URLSearchParams({ actor: "did:plc:other", returnTo: "https://evil.test" });
    show();
    fireEvent.click(screen.getByRole("button", { name: "Back" }));
    expect(replace).toHaveBeenCalledWith("/social");
  });
});
