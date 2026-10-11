import { beforeEach, afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import * as Auth from "@/hooks/useAuth";
import * as Navigation from "next/navigation";
import { socialPostPageHref } from "@/lib/socialPostNavigation";
import * as Client from "@/lib/blueskyPostClient";
import { InteractiveSocialPost } from "@/components/Social/InteractiveSocialPost";
import { SocialPostCard } from "@/components/Social/SocialPostCard";
import { SocialPostLink } from "@/components/Social/SocialPostLink";
import { SocialPostMenu } from "@/components/Social/SocialPostMenu";
import { SocialFeedPosts } from "@/components/Social/SocialFeedPosts";

const did = "did:plc:viewer";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const post: AppBskyFeedDefs.PostView & { $type: "app.bsky.feed.defs#postView" } = { $type: "app.bsky.feed.defs#postView", uri: "at://did:plc:other/app.bsky.feed.post/test", cid: "bafyreia", author: { did: "did:plc:other", handle: "other.test" }, record: { $type: "app.bsky.feed.post", text: "Tap This Post", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z", replyCount: 1 };
const push = mock(() => {});
const restore: (() => void)[] = [];
beforeEach(() => {
 push.mockClear();
 const router = spyOn(Navigation, "useRouter").mockReturnValue({ push, replace: mock(() => {}) } as unknown as ReturnType<typeof Navigation.useRouter>);
 const path = spyOn(Navigation, "usePathname").mockReturnValue("/social");
 const params = spyOn(Navigation, "useSearchParams").mockReturnValue(new URLSearchParams() as ReturnType<typeof Navigation.useSearchParams>);
 restore.push(() => router.mockRestore(), () => path.mockRestore(), () => params.mockRestore());
 for (const [name, value] of Object.entries({ HTMLElement: window.HTMLElement, HTMLInputElement: window.HTMLInputElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, DOMRect: window.DOMRect, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
  Object.defineProperty(globalThis, name, { configurable: true, value });
  restore.push(() => { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); });
 }
});
afterEach(() => { cleanup(); restore.splice(0).forEach(fn => fn()); });
function show(item: AppBskyFeedDefs.FeedViewPost = { post }) {
 const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }), oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
 restore.push(() => auth.mockRestore());
 return render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } })}><InteractiveSocialPost item={item} moderation={moderation} /></QueryClientProvider>);
}
describe("Social Post Interactions", () => {
 it("renders parent and reply in one card and omits a later standalone parent", () => {
  const parent = { ...post, replyCount: 99, uri: `${post.uri}parent`, record: { $type: "app.bsky.feed.post", text: "Grouped Parent", createdAt: "2026-10-10T00:00:00Z" } };
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }), oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
  restore.push(() => auth.mockRestore());
  render(<QueryClientProvider client={new QueryClient()}><SocialFeedPosts items={[{ post, reply: { parent, root: parent } }, { post: parent }]} moderation={moderation} /></QueryClientProvider>);
  const group = screen.getByLabelText("Post Conversation");
  expect(group.classList.contains("border")).toBe(true);
  expect(screen.getByText("Thread · 2 Posts")).toBeTruthy();
  expect(group.querySelectorAll("article")).toHaveLength(2);
  expect([...group.querySelectorAll("article")].every(article => !article.classList.contains("border"))).toBe(true);
  expect(screen.getAllByText("Grouped Parent")).toHaveLength(1);
  fireEvent.click(screen.getByText("Grouped Parent"));
  expect(push).toHaveBeenCalledWith(socialPostPageHref(parent.uri, "/social"));
 });
 it("shows the reply parent and navigates internally without a post dialog", () => {
  const parent = { ...post, uri: `${post.uri}parent`, record: { $type: "app.bsky.feed.post", text: "Original Parent", createdAt: "2026-10-10T00:00:00Z" } };
  show({ post, reply: { parent, root: parent } });
  fireEvent.click(screen.getByText("Original Parent"));
  expect(push).toHaveBeenCalledWith(socialPostPageHref(parent.uri, "/social"));
  expect(screen.queryByRole("dialog") === null).toBe(true);
 });
 it("withholds muted reply parents and preserves unavailable context", () => {
  const parent = { ...post, uri: `${post.uri}parent`, author: { ...post.author, viewer: { muted: true } }, record: { $type: "app.bsky.feed.post", text: "Secret Parent", createdAt: "2026-10-10T00:00:00Z" } };
  const view = show({ post, reply: { parent, root: parent } });
  expect(screen.queryByText("Secret Parent")).toBeNull();
  expect(screen.getByText("Original post withheld by your moderation settings.")).toBeTruthy();
  expect(screen.getByText("Thread")).toBeTruthy();
  expect(screen.queryByText("Thread · 2 Posts")).toBeNull();
  view.rerender(<QueryClientProvider client={new QueryClient()}><InteractiveSocialPost item={{ post, reply: { parent: { $type: "app.bsky.feed.defs#notFoundPost", uri: parent.uri, notFound: true }, root: parent } }} moderation={moderation} /></QueryClientProvider>);
  expect(screen.getByText("Original post unavailable.")).toBeTruthy();
  expect(screen.getByText("Thread")).toBeTruthy();
 });
 it("opens quoted content internally without opening the enclosing post", () => {
  const quote = { $type: "app.bsky.embed.record#viewRecord", uri: `${post.uri}quote`, cid: post.cid, author: post.author, value: { $type: "app.bsky.feed.post", text: "Quoted Content", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: post.indexedAt };
  show({ post: { ...post, embed: { $type: "app.bsky.embed.record#view", record: quote } } });
  fireEvent.click(screen.getByText("Quoted Content"));
  expect(push).toHaveBeenCalledTimes(1);
  expect(push).toHaveBeenCalledWith(socialPostPageHref(quote.uri, "/social"));
  expect(screen.queryByRole("dialog") === null).toBe(true);
 });
 it("opens URI-only notification links through the internal route", () => {
  render(<SocialPostLink uri={post.uri} moderation={moderation} />);
  fireEvent.click(screen.getByRole("button", { name: "Open Post" }));
  expect(push).toHaveBeenCalledWith(socialPostPageHref(post.uri, "/social"));
 });

 it("offers message sharing as a draft and copies the canonical link explicitly", async () => {
  const copy = mock(async () => {});
  const descriptor = Object.getOwnPropertyDescriptor(navigator, "clipboard");
  Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: copy } });
  restore.push(() => { if (descriptor) Object.defineProperty(navigator, "clipboard", descriptor); else Reflect.deleteProperty(navigator, "clipboard"); });
  render(<SocialPostMenu uri={post.uri} className="" />);
  fireEvent.click(screen.getByRole("button", { name: "More Post Actions" }));
  const send = await screen.findByRole("menuitem", { name: "Send Message" });
  const url = "https://bsky.app/profile/did%3Aplc%3Aother/post/test";
  expect(send.getAttribute("href")).toBe(`/social/messages?draft=${encodeURIComponent(url)}`);
  expect(copy).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("menuitem", { name: "Copy Link" }));
  await waitFor(() => expect(screen.getByRole("status").textContent).toBe("Post Link Copied"));
  expect(copy).toHaveBeenCalledWith(url);
 });
 it("shows a recoverable error when copying a post link is rejected", async () => {
  const descriptor = Object.getOwnPropertyDescriptor(navigator, "clipboard");
  Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: async () => { throw new Error("Denied"); } } });
  restore.push(() => { if (descriptor) Object.defineProperty(navigator, "clipboard", descriptor); else Reflect.deleteProperty(navigator, "clipboard"); });
  render(<SocialPostMenu uri={post.uri} className="" />);
  fireEvent.click(screen.getByRole("button", { name: "More Post Actions" }));
  fireEvent.click(await screen.findByRole("menuitem", { name: "Copy Link" }));
  await waitFor(() => expect(screen.getByRole("status").textContent).toContain("Unable to copy"));
 });
 it("opens content and reply actions on the post page", () => {
  show();
  expect(screen.queryByText(/^Thread/)).toBeNull();
  fireEvent.click(screen.getByText("Tap This Post"));
  expect(push).toHaveBeenCalledWith(socialPostPageHref(post.uri, "/social"));
  fireEvent.click(screen.getByRole("button", { name: "Open Replies (1)" }));
  expect(push).toHaveBeenCalledTimes(2);
  expect(screen.queryByRole("dialog") === null).toBe(true);
 });
 it("does not open content when a nested link is clicked, and remains keyboard accessible", () => {
  const open = mock(() => {});
  render(<SocialPostCard item={{ post }} moderation={moderation} onOpen={open} />);
  fireEvent.click(screen.getByText("other.test"));
  expect(open).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("link", { name: "Open Post" }));
  expect(open).toHaveBeenCalledTimes(1);
 });
 it("keeps withheld posts from rendering actions or fetching a conversation", () => {
  const fetch = spyOn(Client, "getBlueskyPostThread").mockRejectedValue(new Error("must not run"));
  restore.push(() => fetch.mockRestore());
  const hidden = { ...moderation, prefs: { ...moderation.prefs, hiddenPosts: [post.uri] } };
  render(<SocialPostCard item={{ post }} moderation={hidden} actions={<button>Unsafe Action</button>} />);
  expect(screen.queryByText("Unsafe Action")).toBeNull();
  expect(fetch).not.toHaveBeenCalled();
 });
});
