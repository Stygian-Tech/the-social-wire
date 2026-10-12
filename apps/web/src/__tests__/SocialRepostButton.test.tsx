import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as storedAuth from "@/lib/auth";
import * as compose from "@/lib/blueskyComposeClient";
import { SocialRepostButton } from "@/components/Social/SocialRepostButton";
import { SocialPostCard } from "@/components/Social/SocialPostCard";

const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
const moderation: ModerationOpts = { userDid: oauth.did, prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: "did:plc:labeler", labels: {} }], mutedWords: [], hiddenPosts: [] } };
const post: AppBskyFeedDefs.PostView = {
  uri: "at://did:plc:author/app.bsky.feed.post/selected",
  cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
  author: { did: "did:plc:author", handle: "author.test" },
  record: { $type: "app.bsky.feed.post", text: "Selected Post", createdAt: "2026-10-11T00:00:00Z" },
  indexedAt: "2026-10-11T00:00:00Z",
  replyCount: 4,
};
const result = { uri: `at://${oauth.did}/app.bsky.feed.post/new`, cid: post.cid };
const restores: (() => void)[] = [];
let cache: QueryClient;

beforeEach(() => {
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const stored = spyOn(storedAuth, "getStoredOAuthDid").mockReturnValue(oauth.did);
  const account = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession: () => oauth } as ReturnType<typeof auth.useAuth>);
  restores.push(() => stored.mockRestore(), () => account.mockRestore());
  const values = { DOMRect: window.DOMRect, Element: window.Element, HTMLElement: window.HTMLElement, Node: window.Node, MutationObserver: window.MutationObserver, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout };
  for (const [name, value] of Object.entries(values)) {
    const original = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (original) Object.defineProperty(globalThis, name, original); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(async () => {
  await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); });
  cache.clear();
  restores.splice(0).reverse().forEach(restore => restore());
});

let onRepost: ReturnType<typeof mock>;
function button(target = post, reposted = false, pending = false) {
  return <SocialRepostButton post={target} moderation={moderation} className="repost-action" reposted={reposted} repostCount={8} pending={pending} onRepost={onRepost} />;
}
function show(target = post, reposted = false, pending = false) {
  onRepost = mock(() => {});
  return render(<QueryClientProvider client={cache}>{button(target, reposted, pending)}</QueryClientProvider>);
}
async function openMenu() {
  fireEvent.click(screen.getByRole("button", { name: "Repost (8)" }));
  return await screen.findByRole("menu");
}
async function openQuote() {
  await openMenu();
  fireEvent.click(screen.getByRole("menuitem", { name: "Quote Post" }));
  return await screen.findByRole("textbox", { name: "Quote Text" }) as HTMLTextAreaElement;
}

it("offers Repost and Quote Post without reposting until an option is chosen", async () => {
  show();
  await openMenu();
  expect(onRepost).not.toHaveBeenCalled();
  expect(screen.getByRole("menuitem", { name: "Quote Post" })).toBeTruthy();
  fireEvent.click(screen.getByRole("menuitem", { name: "Repost" }));
  expect(onRepost).toHaveBeenCalledTimes(1);
  expect(screen.queryByRole("dialog")).toBeNull();
});

it("offers Undo Repost for an already reposted post", async () => {
  show(post, true);
  await openMenu();
  fireEvent.click(screen.getByRole("menuitem", { name: "Undo Repost" }));
  expect(onRepost).toHaveBeenCalledTimes(1);
});

it("previews the selected target and publishes only on explicit submission with quoteTo", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue(result);
  restores.push(() => publish.mockRestore());
  show();
  const field = await openQuote();
  expect(screen.getByText("Selected Post")).toBeTruthy();
  expect(screen.getByText("Quoting @author.test")).toBeTruthy();
  expect(onRepost).not.toHaveBeenCalled();
  expect(publish).not.toHaveBeenCalled();
  expect(screen.getByRole("button", { name: "Post Quote" }).hasAttribute("disabled")).toBe(true);
  fireEvent.change(field, { target: { value: "My Quote Comment" } });
  fireEvent.click(screen.getByRole("button", { name: "Post Quote" }));
  await screen.findByText("Quote Post Published");
  expect(publish).toHaveBeenCalledTimes(1);
  expect(publish.mock.calls[0]![0]).toMatchObject({ session: oauth, text: "My Quote Comment", quoteTo: post });
  expect(publish.mock.calls[0]![0].replyTo).toBeUndefined();
  expect(screen.queryByRole("dialog")).toBeNull();
});

it("keeps repost available when quotes are disabled", async () => {
  show({ ...post, viewer: { embeddingDisabled: true } });
  await openMenu();
  expect(screen.getByRole("menuitem", { name: "Quote Post" }).getAttribute("aria-disabled")).toBe("true");
  fireEvent.click(screen.getByRole("menuitem", { name: "Quote Post" }));
  expect(screen.queryByRole("dialog")).toBeNull();
  fireEvent.click(screen.getByRole("menuitem", { name: "Repost" }));
  expect(onRepost).toHaveBeenCalledTimes(1);
});

it.each(["signed-out", "pending", "mismatched-viewer"])("disables the action for %s", state => {
  if (state !== "pending") {
    const account = spyOn(auth, "useAuth").mockReturnValue({ session: state === "signed-out" ? null : { did: "did:plc:other" }, getOAuthSession: () => undefined } as unknown as ReturnType<typeof auth.useAuth>);
    restores.push(() => account.mockRestore());
  }
  show(post, false, state === "pending");
  const trigger = screen.getByRole("button", { name: "Repost (8)" });
  expect(trigger.hasAttribute("disabled")).toBe(true);
  fireEvent.click(trigger);
  expect(screen.queryByRole("menu")).toBeNull();
  expect(onRepost).not.toHaveBeenCalled();
});

it("cancels without publishing and resets the draft on reopening", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue(result);
  restores.push(() => publish.mockRestore());
  show();
  fireEvent.change(await openQuote(), { target: { value: "Cancelled Draft" } });
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(publish).not.toHaveBeenCalled();
  expect((await openQuote()).value).toBe("");
});

it("preserves failed quotes and retries with the same target and draft", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockRejectedValueOnce(new Error("Quote Failed")).mockResolvedValue(result);
  restores.push(() => publish.mockRestore());
  show();
  const field = await openQuote();
  fireEvent.change(field, { target: { value: "Preserve My Quote" } });
  fireEvent.click(screen.getByRole("button", { name: "Post Quote" }));
  await screen.findByRole("alert");
  expect(field.value).toBe("Preserve My Quote");
  fireEvent.click(screen.getByRole("button", { name: "Post Quote" }));
  await screen.findByText("Quote Post Published");
  expect(publish).toHaveBeenCalledTimes(2);
  expect(publish.mock.calls[1]![0]).toMatchObject({ text: "Preserve My Quote", quoteTo: post });
});

it("rejects changed stored accounts without publishing the quote draft", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue(result);
  const stored = spyOn(storedAuth, "getStoredOAuthDid").mockReturnValue("did:plc:other");
  restores.push(() => publish.mockRestore(), () => stored.mockRestore());
  show();
  const field = await openQuote();
  fireEvent.change(field, { target: { value: "Private Quote Draft" } });
  fireEvent.click(screen.getByRole("button", { name: "Post Quote" }));
  await screen.findByRole("alert");
  expect(publish).not.toHaveBeenCalled();
  expect(field.value).toBe("Private Quote Draft");
});

it("keeps menu and composer portal interactions from opening the parent card", async () => {
  const onOpen = mock(() => {});
  onRepost = mock(() => {});
  render(<QueryClientProvider client={cache}><SocialPostCard item={{ post }} moderation={moderation} onOpen={onOpen} actions={button()} /></QueryClientProvider>);
  await openMenu();
  fireEvent.click(screen.getByRole("menuitem", { name: "Quote Post" }));
  const field = await screen.findByRole("textbox", { name: "Quote Text" });
  fireEvent.click(field);
  fireEvent.click(screen.getByRole("dialog").querySelector("article")!);
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  expect(onOpen).not.toHaveBeenCalled();
  expect(onRepost).not.toHaveBeenCalled();
});
