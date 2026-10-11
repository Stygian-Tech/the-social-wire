import { beforeEach, afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import * as Auth from "@/hooks/useAuth";
import * as Client from "@/lib/blueskyPostClient";
import { InteractiveSocialPost } from "@/components/Social/InteractiveSocialPost";
import { SocialPostCard } from "@/components/Social/SocialPostCard";
import { SocialPostLink } from "@/components/Social/SocialPostLink";
import { SocialPostMenu } from "@/components/Social/SocialPostMenu";

const did = "did:plc:viewer";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const post: AppBskyFeedDefs.PostView & { $type: "app.bsky.feed.defs#postView" } = { $type: "app.bsky.feed.defs#postView", uri: "at://did:plc:other/app.bsky.feed.post/test", cid: "bafyreia", author: { did: "did:plc:other", handle: "other.test" }, record: { $type: "app.bsky.feed.post", text: "Tap This Post", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z", replyCount: 1 };
const restore: (() => void)[] = [];
beforeEach(() => {
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
 it("shows the reply parent and opens it in the internal viewer", async () => {
  const parent = { ...post, uri: `${post.uri}parent`, record: { $type: "app.bsky.feed.post", text: "Original Parent", createdAt: "2026-10-10T00:00:00Z" } };
  const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post: parent } });
  restore.push(() => fetch.mockRestore());
  show({ post, reply: { parent, root: parent } });
  expect(screen.getByRole("region", { name: "Replying To" }).textContent).toContain("Original Parent");
  fireEvent.click(screen.getByText("Original Parent"));
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  expect(fetch.mock.calls[0]![0].uri).toBe(parent.uri);
  expect(within(screen.getByRole("dialog")).getByText("Original Parent")).toBeTruthy();
 });
 it("withholds muted reply parents and preserves unavailable context", () => {
  const parent = { ...post, uri: `${post.uri}parent`, author: { ...post.author, viewer: { muted: true } }, record: { $type: "app.bsky.feed.post", text: "Secret Parent", createdAt: "2026-10-10T00:00:00Z" } };
  const view = show({ post, reply: { parent, root: parent } });
  expect(screen.queryByText("Secret Parent")).toBeNull();
  expect(screen.getByText("Original post withheld by your moderation settings.")).toBeTruthy();
  view.rerender(<QueryClientProvider client={new QueryClient()}><InteractiveSocialPost item={{ post, reply: { parent: { $type: "app.bsky.feed.defs#notFoundPost", uri: parent.uri, notFound: true }, root: parent } }} moderation={moderation} /></QueryClientProvider>);
  expect(screen.getByText("Original post unavailable.")).toBeTruthy();
 });
 it("navigates conversation parents and replies inside one dialog", async () => {
  const parent = { ...post, uri: `${post.uri}parent`, record: { $type: "app.bsky.feed.post", text: "Thread Parent", createdAt: "2026-10-10T00:00:00Z" } };
  const reply = { ...post, uri: `${post.uri}reply`, record: { $type: "app.bsky.feed.post", text: "Thread Reply", createdAt: "2026-10-10T00:00:00Z" } };
  const fetch = spyOn(Client, "getBlueskyPostThread").mockImplementation(async args => ({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post: args.uri === parent.uri ? parent : args.uri === reply.uri ? reply : post, parent: args.uri === post.uri ? { $type: "app.bsky.feed.defs#threadViewPost", post: parent } : undefined, replies: args.uri === post.uri || args.uri === parent.uri ? [{ $type: "app.bsky.feed.defs#threadViewPost", post: reply }] : [] } }));
  restore.push(() => fetch.mockRestore());
  show(); fireEvent.click(screen.getByText("Tap This Post"));
  fireEvent.click(await screen.findByText("Thread Parent"));
  await waitFor(() => expect(fetch.mock.calls.at(-1)![0].uri).toBe(parent.uri));
  fireEvent.click(await screen.findByText("Thread Reply"));
  await waitFor(() => expect(fetch.mock.calls.at(-1)![0].uri).toBe(reply.uri));
  expect(screen.getAllByRole("dialog")).toHaveLength(1);
 });
 it("opens quoted content internally without opening the enclosing post", async () => {
  const quote = { $type: "app.bsky.embed.record#viewRecord", uri: `${post.uri}quote`, cid: post.cid, author: post.author, value: { $type: "app.bsky.feed.post", text: "Quoted Content", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: post.indexedAt };
  const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#notFoundPost", uri: quote.uri, notFound: true } });
  restore.push(() => fetch.mockRestore());
  show({ post: { ...post, embed: { $type: "app.bsky.embed.record#view", record: quote } } });
  fireEvent.click(screen.getByText("Quoted Content"));
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  expect(fetch.mock.calls[0]![0].uri).toBe(quote.uri);
  await waitFor(() => expect(within(screen.getByRole("dialog")).queryByText("Quoted Content")).toBeNull());
  expect(within(screen.getByRole("dialog")).queryByRole("button", { name: "Like" })).toBeNull();
  expect(within(screen.getByRole("dialog")).getByText("This conversation is unavailable.")).toBeTruthy();
  expect(screen.getAllByRole("dialog")).toHaveLength(1);
 });
 it("removes stale content and actions when the current thread is blocked", async () => {
  const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#blockedPost", uri: post.uri, blocked: true, author: { did: post.author.did } } });
  restore.push(() => fetch.mockRestore());
  show(); fireEvent.click(screen.getByText("Tap This Post"));
  await waitFor(() => expect(within(screen.getByRole("dialog")).getByText("This conversation is unavailable.")).toBeTruthy());
  expect(within(screen.getByRole("dialog")).queryByText("Tap This Post")).toBeNull();
  expect(within(screen.getByRole("dialog")).queryByRole("button", { name: "More Post Actions" })).toBeNull();
 });
 it("opens URI-only notification links in the internal viewer", async () => {
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }), oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
  const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post } });
  restore.push(() => auth.mockRestore(), () => fetch.mockRestore());
  render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}><SocialPostLink uri={post.uri} moderation={moderation} /></QueryClientProvider>);
  fireEvent.click(screen.getByRole("button", { name: "Open Post" }));
  await waitFor(() => expect(within(screen.getByRole("dialog")).getByText("Tap This Post")).toBeTruthy());
  expect(fetch.mock.calls[0]![0].uri).toBe(post.uri);
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
 it("opens content and replies in a conversation dialog without a View Post button", async () => {
  const reply = { ...post, uri: `${post.uri}reply`, record: { $type: "app.bsky.feed.post", text: "A Conversation Reply", createdAt: "2026-10-10T00:00:00Z" } };
  const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post, replies: [{ $type: "app.bsky.feed.defs#threadViewPost", post: reply }] } });
  restore.push(() => fetch.mockRestore());
  show();
  expect(screen.queryByText("View Post")).toBeNull();
  fireEvent.click(screen.getByText("Tap This Post"));
  await waitFor(() => expect(screen.getByText("A Conversation Reply")).toBeTruthy());
  expect(screen.getByRole("dialog")).toBeTruthy();
  expect(fetch).toHaveBeenCalledTimes(1);
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
