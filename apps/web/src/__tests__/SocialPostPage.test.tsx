import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import * as Navigation from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import * as Client from "@/lib/blueskyPostClient";
import * as Bookmarks from "@/lib/blueskyBookmarksClient";
import * as ThreadNavigation from "@/hooks/useSocialThreadNavigation";
import { SidebarProvider } from "@/components/ui/sidebar";
import SocialPostPage from "@/app/social/post/page";
import { safeSocialPostReturnPath, socialPostPageHref } from "@/lib/socialPostNavigation";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

const did = "did:plc:viewer";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const post = { uri: "at://did:plc:other/app.bsky.feed.post/test", cid: "bafyreia", author: { did: "did:plc:other", handle: "other.test" }, record: { $type: "app.bsky.feed.post", text: "Selected Post", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z" };
const push = mock(() => {});
const replace = mock((href: string, options?: { scroll: boolean }) => { void href; void options; });
const openThread = mock((uri: string, container: HTMLElement | null) => { void uri; void container; });
const threadBack = mock(() => replace(safeSocialPostReturnPath(params.get("returnTo")), { scroll: false }));
const restoreThread = mock((container: HTMLElement | null) => { void container; return true; });
let focused = false;
let params: URLSearchParams;
let catalogError: Error | undefined;
const restores: (() => void)[] = [];
let cache: QueryClient;
beforeEach(() => {
  const media = Object.getOwnPropertyDescriptor(window, "matchMedia");
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
  restores.push(() => { if (media) Object.defineProperty(window, "matchMedia", media); else Reflect.deleteProperty(window, "matchMedia"); });
  for (const [name, value] of Object.entries({ HTMLElement: window.HTMLElement, HTMLInputElement: window.HTMLInputElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, DOMRect: window.DOMRect, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); });
  }
  params = new URLSearchParams({ uri: post.uri, returnTo: "/social?feed=original" });
  catalogError = undefined; push.mockClear(); replace.mockClear();
  focused = false; openThread.mockClear(); threadBack.mockClear(); restoreThread.mockClear();
  cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ push, replace } as unknown as ReturnType<typeof Navigation.useRouter>);
  const path = spyOn(Navigation, "usePathname").mockReturnValue("/social/post");
  const search = spyOn(Navigation, "useSearchParams").mockImplementation(() => params as ReturnType<typeof Navigation.useSearchParams>);
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }), oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
  const catalog = spyOn(Catalog, "useBlueskySocialCatalog").mockImplementation(() => ({ data: { feeds: [], moderation }, isError: !!catalogError, error: catalogError, refetch: mock(async () => undefined) } as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>));
  const threadNavigation = spyOn(ThreadNavigation, "useSocialThreadNavigation").mockImplementation(() => ({ openThread, back: threadBack, restore: restoreThread, focused }));
  restores.push(() => router.mockRestore(), () => path.mockRestore(), () => search.mockRestore(), () => auth.mockRestore(), () => catalog.mockRestore(), () => threadNavigation.mockRestore());
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function show() { return render(<QueryClientProvider client={cache}><SidebarProvider><SocialPostPage /></SidebarProvider></QueryClientProvider>); }
function deepConversation() {
  type Thread = AppBskyFeedDefs.ThreadViewPost & { $type: "app.bsky.feed.defs#threadViewPost" };
  const root: Thread = { $type: "app.bsky.feed.defs#threadViewPost", post, replies: [] };
  const nodes: Thread[] = [];
  let parent = root;
  for (let depth = 0; depth < 6; depth++) {
    const node: Thread = { $type: "app.bsky.feed.defs#threadViewPost", post: { ...post, uri: `${post.uri}depth${depth}`, record: { ...post.record, text: `Reply Depth ${depth}` } }, replies: [] };
    parent.replies = [node];
    nodes.push(node); parent = node;
  }
  const sibling: Thread = { $type: "app.bsky.feed.defs#threadViewPost", post: { ...post, uri: `${post.uri}sibling`, record: { ...post.record, text: "Following Sibling" } }, replies: [] };
  root.replies!.push(sibling);
  return { root, nodes, sibling };
}

describe("on-page post viewer", () => {
  it("provides actions on every ancestor with that ancestor as the reply target", async () => {
    const ancestor = { ...post, uri: `${post.uri}ancestor`, author: { did: "did:plc:ancestor", handle: "ancestor.test" }, record: { ...post.record, text: "Ancestor With Actions" } };
    const parent = { ...post, uri: `${post.uri}parent`, author: { did: "did:plc:parent", handle: "parent.test" }, record: { ...post.record, text: "Parent With Actions" } };
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post, parent: { $type: "app.bsky.feed.defs#threadViewPost", post: parent, parent: { $type: "app.bsky.feed.defs#threadViewPost", post: ancestor } } } });
    restores.push(() => fetch.mockRestore());
    show();
    await screen.findByText("Ancestor With Actions");
    expect(screen.getAllByRole("generic", { name: "Post Actions" })).toHaveLength(3);
    for (const [text, handle] of [["Ancestor With Actions", "ancestor.test"], ["Parent With Actions", "parent.test"], ["Selected Post", "other.test"]]) {
      const card = screen.getByText(text!).closest("article")!;
      expect(within(card).getByRole("button", { name: "Like (0)" })).toBeTruthy();
      expect(within(card).getByRole("button", { name: "Repost (0)" })).toBeTruthy();
      expect(within(card).getByRole("button", { name: "Bookmark Post" })).toBeTruthy();
      fireEvent.click(within(card).getByRole("button", { name: "Reply (0)" }));
      expect(screen.getByText(`Replying To @${handle}`)).toBeTruthy();
      fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
      await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    }
    expect(push).not.toHaveBeenCalled();
  });

  it("opens Show More at the boundary card while preserving following siblings", async () => {
    const { root, nodes } = deepConversation();
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: root });
    restores.push(() => fetch.mockRestore());
    const view = show();
    await screen.findByText("Reply Depth 3");
    expect(screen.queryByText("Reply Depth 4")).toBeNull();
    expect(screen.queryByText("Reply Depth 5")).toBeNull();
    expect(screen.getByText("Following Sibling")).toBeTruthy();
    const row = view.container.querySelector('[data-reply-depth="3"]') as HTMLElement;
    expect(row.dataset.threadPostUri).toBe(nodes[3]!.post.uri);
    const more = within(row).getByRole("button", { name: "Show More" });
    expect(screen.getAllByRole("button", { name: "Show More" })).toHaveLength(1);
    fireEvent.click(more);
    const container = screen.getByRole("region", { name: "Post Conversation" }).parentElement;
    expect(openThread).toHaveBeenCalledWith(nodes[3]!.post.uri, container);
    expect(push).not.toHaveBeenCalled();
    expect(restoreThread).toHaveBeenCalledTimes(1);
    expect(restoreThread).toHaveBeenCalledWith(container);
  });
  for (const state of ["muted", "invalid"] as const) it(`withholds Show More for a ${state} boundary post`, async () => {
    const { root, nodes } = deepConversation();
    if (state === "muted") nodes[3]!.post.author = { ...nodes[3]!.post.author, viewer: { muted: true } };
    else nodes[3]!.post.record = {};
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: root });
    restores.push(() => fetch.mockRestore());
    show();
    await screen.findByText("Following Sibling");
    expect(screen.queryByRole("button", { name: "Show More" })).toBeNull();
    expect(screen.queryByText("Reply Depth 3")).toBeNull();
    expect(screen.queryByText("Reply Depth 4")).toBeNull();
  });
  it("starts a focused conversation at its selected post while retaining immediate-parent context", async () => {
    focused = true;
    const parent = { ...post, uri: `${post.uri}parent`, author: { did: "did:plc:earlier", handle: "earlier.test" }, record: { ...post.record, text: "Earlier Ancestor" } };
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post, parent: { $type: "app.bsky.feed.defs#threadViewPost", post: parent } } });
    restores.push(() => fetch.mockRestore());
    show();
    await screen.findByText("Selected Post");
    expect(screen.queryByText("Earlier Ancestor")).toBeNull();
    expect(screen.getByText("@earlier.test")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Back" }));
    expect(threadBack).toHaveBeenCalledTimes(1);
  });
  it("indents nested replies, retains sibling order, and identifies the immediate parent", async () => {
    const first = { ...post, uri: `${post.uri}first`, author: { did: "did:plc:first", handle: "first.test" }, record: { ...post.record, text: "First Reply" } };
    const nested = { ...post, uri: `${post.uri}nested`, record: { ...post.record, text: "Nested Reply" } };
    const sibling = { ...post, uri: `${post.uri}sibling`, record: { ...post.record, text: "Sibling Reply" } };
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post, replies: [{ $type: "app.bsky.feed.defs#threadViewPost", post: first, replies: [{ $type: "app.bsky.feed.defs#threadViewPost", post: nested }] }, { $type: "app.bsky.feed.defs#threadViewPost", post: sibling }] } });
    restores.push(() => fetch.mockRestore());
    const view = show();
    await screen.findByText("Nested Reply");
    const rows = Array.from(view.container.querySelectorAll("[data-reply-depth]"));
    expect(rows.map(row => row.getAttribute("data-reply-depth"))).toEqual(["0", "1", "0"]);
    expect(rows[1]?.className).toContain("ml-3");
    expect(rows[1]?.className).toContain("border-l-2");
    expect(rows[1]?.textContent).toContain("first.test");
    fireEvent.click(screen.getByText("Nested Reply"));
    expect(push).toHaveBeenLastCalledWith(socialPostPageHref(nested.uri, "/social?feed=original"));
  });
  it("targets reply engagement, bookmarks, menu links, and its own conversation independently", async () => {
    const reply = { ...post, uri: `${post.uri}reply`, cid: "reply-cid", replyCount: 3, record: { ...post.record, text: "Reply With Actions" } };
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post, replies: [{ $type: "app.bsky.feed.defs#threadViewPost", post: reply }] } });
    const engage = spyOn(Client, "setBlueskyPostEngagement").mockResolvedValue("at://did:plc:viewer/app.bsky.feed.like/action");
    const bookmark = spyOn(Bookmarks, "setBlueskyBookmark").mockResolvedValue(undefined);
    restores.push(() => fetch.mockRestore(), () => engage.mockRestore(), () => bookmark.mockRestore());
    const copy = mock(async () => {});
    const clipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard");
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: copy } });
    restores.push(() => { if (clipboard) Object.defineProperty(navigator, "clipboard", clipboard); else Reflect.deleteProperty(navigator, "clipboard"); });
    show();
    const replies = within(await screen.findByRole("region", { name: "Replies" }));
    await replies.findByText("Reply With Actions");
    fireEvent.click(replies.getByRole("button", { name: "Like (0)" }));
    await waitFor(() => expect(engage).toHaveBeenCalledTimes(1));
    expect(engage.mock.calls[0]![0]).toMatchObject({ kind: "like", uri: reply.uri, cid: reply.cid });
    await waitFor(() => expect((replies.getByRole("button", { name: "Repost (0)" }) as HTMLButtonElement).disabled).toBe(false));
    fireEvent.click(replies.getByRole("button", { name: "Repost (0)" }));
    expect(engage).toHaveBeenCalledTimes(1);
    fireEvent.click(await screen.findByRole("menuitem", { name: "Repost" }));
    await waitFor(() => expect(engage).toHaveBeenCalledTimes(2));
    expect(engage.mock.calls[1]![0]).toMatchObject({ kind: "repost", uri: reply.uri, cid: reply.cid });
    fireEvent.click(replies.getByRole("button", { name: "Bookmark Post" }));
    await waitFor(() => expect(bookmark).toHaveBeenCalledTimes(1));
    expect(bookmark.mock.calls[0]![0]).toMatchObject({ uri: reply.uri, cid: reply.cid, saved: true });
    fireEvent.click(replies.getByRole("button", { name: "Reply (3)" }));
    expect(push).not.toHaveBeenCalled();
    expect(screen.getByRole("dialog", { name: "Reply" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    fireEvent.click(replies.getByRole("button", { name: "More Post Actions" }));
    const url = "https://bsky.app/profile/did%3Aplc%3Aother/post/testreply";
    expect((await screen.findByRole("menuitem", { name: "Send Message" })).getAttribute("href")).toBe(`/social/messages?draft=${encodeURIComponent(url)}`);
    fireEvent.click(screen.getByRole("menuitem", { name: "Copy Link" }));
    await waitFor(() => expect(copy).toHaveBeenCalledWith(url));
    expect(push).not.toHaveBeenCalled();
  });
  it("displays a conversation with Back first in the top bar and navigates parent/reply routes", async () => {
    const parent = { ...post, uri: `${post.uri}parent`, record: { ...post.record, text: "Parent Post" } };
    const reply = { ...post, uri: `${post.uri}reply`, record: { ...post.record, text: "Reply Post" } };
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post, parent: { $type: "app.bsky.feed.defs#threadViewPost", post: parent }, replies: [{ $type: "app.bsky.feed.defs#threadViewPost", post: reply }] } });
    restores.push(() => fetch.mockRestore());
    show();
    await screen.findByText("Selected Post");
    expect(screen.queryByRole("dialog") === null).toBe(true);
    expect(screen.getByRole("banner").querySelector("button")?.getAttribute("aria-label")).toBe("Back");
    fireEvent.click(screen.getByText("Parent Post"));
    expect(push).toHaveBeenLastCalledWith(socialPostPageHref(parent.uri, "/social?feed=original"));
    fireEvent.click(screen.getByText("Reply Post"));
    expect(push).toHaveBeenLastCalledWith(socialPostPageHref(reply.uri, "/social?feed=original"));
    fireEvent.click(screen.getByRole("button", { name: "Back" }));
    expect(replace).toHaveBeenCalledWith("/social?feed=original", { scroll: false });
  });
  it("withholds a muted reply and its action rail while keeping root actions available", async () => {
    const reply = { ...post, uri: `${post.uri}muted`, author: { ...post.author, viewer: { muted: true } }, record: { ...post.record, text: "Withheld Reply" } };
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post, replies: [{ $type: "app.bsky.feed.defs#threadViewPost", post: reply }] } });
    restores.push(() => fetch.mockRestore());
    show();
    const replies = within(await screen.findByRole("region", { name: "Replies" }));
    expect(replies.queryByText("Withheld Reply") === null).toBe(true);
    expect(replies.queryByRole("button", { name: "More Post Actions" }) === null).toBe(true);
    expect(screen.getAllByRole("button", { name: "More Post Actions" })).toHaveLength(1);
  });
  it("preserves a nested reply without revealing its muted parent's identity", async () => {
    const parent = { ...post, uri: `${post.uri}muted`, author: { did: "did:plc:hidden", handle: "hidden-parent.test", viewer: { muted: true } }, record: { ...post.record, text: "Hidden Parent" } };
    const nested = { ...post, uri: `${post.uri}nested`, record: { ...post.record, text: "Visible Nested Reply" } };
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post, replies: [{ $type: "app.bsky.feed.defs#threadViewPost", post: parent, replies: [{ $type: "app.bsky.feed.defs#threadViewPost", post: nested }] }] } });
    restores.push(() => fetch.mockRestore());
    const view = show();
    await screen.findByText("Visible Nested Reply");
    expect(screen.queryByText("Hidden Parent")).toBeNull();
    expect(screen.queryByText(/hidden-parent\.test/)).toBeNull();
    const row = view.container.querySelector('[data-reply-depth="1"]');
    expect(row?.textContent).toContain("Replying To a withheld post");
    expect(within(row as HTMLElement).getByRole("button", { name: "More Post Actions" })).toBeTruthy();
  });
  for (const type of ["blockedPost", "notFoundPost"] as const) it(`never shows stale content or actions for ${type}`, async () => {
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: type === "blockedPost" ? { $type: "app.bsky.feed.defs#blockedPost", uri: post.uri, blocked: true, author: { did: post.author.did } } : { $type: "app.bsky.feed.defs#notFoundPost", uri: post.uri, notFound: true } });
    restores.push(() => fetch.mockRestore());
    show();
    await screen.findByText("This conversation is unavailable.");
    expect(screen.queryByText("Selected Post") === null).toBe(true);
    expect(screen.queryByRole("button", { name: "More Post Actions" }) === null).toBe(true);
  });
  it("rejects invalid post links before fetching and safely returns deep links Home", () => {
    params = new URLSearchParams({ uri: "javascript:alert(1)", returnTo: "https://evil.example" });
    const fetch = spyOn(Client, "getBlueskyPostThread").mockRejectedValue(new Error("Must not fetch"));
    restores.push(() => fetch.mockRestore());
    show(); expect(screen.getByRole("alert").textContent).toContain("invalid");
    expect(fetch).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Back" }));
    expect(replace).toHaveBeenCalledWith("/social", { scroll: false });
  });
  it("withholds content after catalog failure and offers permission recovery", async () => {
    catalogError = new Error(SCOPE_RECOVERY_MESSAGE);
    const fetch = spyOn(Client, "getBlueskyPostThread").mockRejectedValue(new Error("Must not fetch"));
    restores.push(() => fetch.mockRestore());
    show();
    await waitFor(() => expect(screen.getByRole("button", { name: "Log In Again" })).toBeTruthy());
    expect(fetch).not.toHaveBeenCalled();
    expect(screen.queryByText("Selected Post") === null).toBe(true);
  });
  it("preserves only safe origin pages including search and profile tab state", () => {
    for (const path of ["/social?list=original", "/social/explore?q=trees&type=posts", "/social/bookmarks", "/me#likes", "/live-post"]) expect(safeSocialPostReturnPath(path)).toBe(path);
    for (const path of ["//evil.example", "/\\evil.example", "https://evil.example", "/social/post?uri=cycle", "/login", "/me/settings", "/social/%2e%2e/login"]) expect(safeSocialPostReturnPath(path)).toBe("/social");
  });
});
