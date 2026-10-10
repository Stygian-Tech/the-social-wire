import { beforeEach, afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import * as Auth from "@/hooks/useAuth";
import * as Client from "@/lib/blueskyPostClient";
import { InteractiveSocialPost } from "@/components/Social/InteractiveSocialPost";
import { SocialPostCard } from "@/components/Social/SocialPostCard";
import { SocialPostMenu } from "@/components/Social/SocialPostMenu";

const did = "did:plc:viewer";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const post: AppBskyFeedDefs.PostView = { uri: "at://did:plc:other/app.bsky.feed.post/test", cid: "bafyreia", author: { did: "did:plc:other", handle: "other.test" }, record: { $type: "app.bsky.feed.post", text: "Tap This Post", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z", replyCount: 1 };
const restore: (() => void)[] = [];
beforeEach(() => {
 for (const [name, value] of Object.entries({ HTMLElement: window.HTMLElement, HTMLInputElement: window.HTMLInputElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, DOMRect: window.DOMRect, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
  Object.defineProperty(globalThis, name, { configurable: true, value });
  restore.push(() => { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); });
 }
});
afterEach(() => { cleanup(); restore.splice(0).forEach(fn => fn()); });
function show() {
 const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }), oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
 restore.push(() => auth.mockRestore());
 return render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } })}><InteractiveSocialPost item={{ post }} moderation={moderation} /></QueryClientProvider>);
}
describe("Social Post Interactions", () => {
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
