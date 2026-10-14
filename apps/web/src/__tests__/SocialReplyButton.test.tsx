import * as draftStorage from "@/lib/composerDraftStorage";
import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as storedAuth from "@/lib/auth";
import * as compose from "@/lib/blueskyComposeClient";
import { SocialReplyButton } from "@/components/Social/SocialReplyButton";

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
  const load = spyOn(draftStorage, "loadComposerDraft").mockResolvedValue(undefined);
  const save = spyOn(draftStorage, "saveComposerDraft").mockResolvedValue(undefined);
  restores.push(() => load.mockRestore(), () => save.mockRestore());
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

function show(target = post) {
  return render(<QueryClientProvider client={cache}><SocialReplyButton post={target} className="reply-action" moderation={moderation} /></QueryClientProvider>);
}
async function open() {
  fireEvent.click(screen.getByRole("button", { name: "Reply (4)" }));
  return await screen.findByRole("textbox", { name: "Reply Text" }) as HTMLTextAreaElement;
}

it("opens the selected post composer and publishes only on explicit submission with scoped cache refresh", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue(result);
  const invalidate = spyOn(cache, "invalidateQueries");
  restores.push(() => publish.mockRestore(), () => invalidate.mockRestore());
  show();
  const field = await open();
  expect(screen.getByText("Replying To @author.test")).toBeTruthy();
  expect(publish).not.toHaveBeenCalled();
  expect(screen.getByRole("button", { name: "Post Reply" }).hasAttribute("disabled")).toBe(true);
  fireEvent.change(field, { target: { value: "Reply To This Post" } });
  fireEvent.click(screen.getByRole("button", { name: "Post Reply" }));
  await screen.findByText("Reply Published");
  expect(publish).toHaveBeenCalledTimes(1);
  expect(publish.mock.calls[0]![0]).toMatchObject({ session: oauth, text: "Reply To This Post", replyTo: post });
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(invalidate).toHaveBeenCalledTimes(1);
  const predicate = invalidate.mock.calls[0]![0]!.predicate!;
  const queryFor = (queryKey: readonly unknown[]) => cache.getQueryCache().build(cache, { queryKey });
  for (const surface of ["thread", "timeline", "profileTimeline", "explore", "bookmarks", "notifications"]) {
    expect(predicate(queryFor(["blueskySocial", oauth.did, surface]))).toBe(true);
    expect(predicate(queryFor(["blueskySocial", "did:plc:other", surface]))).toBe(false);
  }
  expect(predicate(queryFor(["blueskySocial", oauth.did, "catalog"]))).toBe(false);
  expect(predicate(queryFor(["unrelated", oauth.did, "thread"]))).toBe(false);
});

it("prevents duplicate submissions and dismissal while publishing", async () => {
  let finish!: (value: typeof result) => void;
  const publish = spyOn(compose, "createBlueskyPost").mockReturnValue(new Promise(resolve => { finish = resolve; }));
  restores.push(() => publish.mockRestore());
  show();
  const field = await open();
  fireEvent.change(field, { target: { value: "Only Once" } });
  fireEvent.submit(field.closest("form")!);
  fireEvent.submit(field.closest("form")!);
  expect(publish).toHaveBeenCalledTimes(1);
  expect(field.disabled).toBe(true);
  expect(screen.getByRole("button", { name: "Publishing…" }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("button", { name: "Cancel" }).hasAttribute("disabled")).toBe(true);
  expect(screen.queryByRole("button", { name: "Close" })).toBeNull();
  fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape", code: "Escape" });
  expect(screen.getByRole("dialog")).toBeTruthy();
  await act(async () => finish(result));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
});

it("preserves the failed draft and successfully retries without closing prematurely", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockRejectedValueOnce(new Error("Reply Failed")).mockResolvedValue(result);
  restores.push(() => publish.mockRestore());
  show();
  const field = await open();
  fireEvent.change(field, { target: { value: "Keep This Draft" } });
  fireEvent.click(screen.getByRole("button", { name: "Post Reply" }));
  await screen.findByRole("alert");
  expect(field.value).toBe("Keep This Draft");
  expect(screen.getByRole("dialog")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Post Reply" }).hasAttribute("disabled")).toBe(false);
  fireEvent.click(screen.getByRole("button", { name: "Post Reply" }));
  await screen.findByText("Reply Published");
  expect(publish).toHaveBeenCalledTimes(2);
  expect(publish.mock.calls[1]![0].text).toBe("Keep This Draft");
});

it("enforces grapheme and byte limits and preserves cancelled drafts on reopening", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue(result);
  restores.push(() => publish.mockRestore());
  show();
  const field = await open();
  fireEvent.change(field, { target: { value: "a".repeat(301) } });
  expect(screen.getByText("301/300")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Post Reply" }).hasAttribute("disabled")).toBe(true);
  fireEvent.change(field, { target: { value: "👨‍👩‍👧‍👦".repeat(300) } });
  expect(screen.getByText("300/300")).toBeTruthy();
  expect(screen.getByText("Reply Text Exceeds the Size Limit")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Post Reply" }).hasAttribute("disabled")).toBe(true);
  fireEvent.submit(field.closest("form")!);
  expect(publish).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect((await open()).value).toBe("👨‍👩‍👧‍👦".repeat(300));
  expect(screen.getByText("Reply Text Exceeds the Size Limit")).toBeTruthy();
});

it("withholds composition for disabled replies and invalid post records", () => {
  const view = show({ ...post, viewer: { replyDisabled: true } });
  const button = screen.getByRole("button", { name: "Reply (4)" });
  expect(button.hasAttribute("disabled")).toBe(true);
  expect(button.getAttribute("title")).toBe("Replies Are Disabled");
  fireEvent.click(button);
  expect(screen.queryByRole("dialog")).toBeNull();
  view.rerender(<QueryClientProvider client={cache}><SocialReplyButton post={{ ...post, record: { $type: "app.bsky.feed.like" } }} className="reply-action" moderation={moderation} /></QueryClientProvider>);
  expect(screen.getByRole("button", { name: "Reply (4)" }).hasAttribute("disabled")).toBe(true);
});

it("rejects changed stored accounts before publishing and preserves the draft", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue(result);
  const stored = spyOn(storedAuth, "getStoredOAuthDid").mockReturnValue("did:plc:other");
  restores.push(() => publish.mockRestore(), () => stored.mockRestore());
  show();
  const field = await open();
  fireEvent.change(field, { target: { value: "Private Draft" } });
  fireEvent.click(screen.getByRole("button", { name: "Post Reply" }));
  await screen.findByRole("alert");
  expect(publish).not.toHaveBeenCalled();
  expect(field.value).toBe("Private Draft");
});

it("isolates drafts and pending success when the signed-in account changes", async () => {
  let captured!: Parameters<typeof compose.createBlueskyPost>[0];
  let finish!: (value: typeof result) => void;
  const publish = spyOn(compose, "createBlueskyPost").mockImplementation(args => { captured = args; return new Promise(resolve => { finish = resolve; }); });
  const invalidate = spyOn(cache, "invalidateQueries");
  restores.push(() => publish.mockRestore(), () => invalidate.mockRestore());
  const view = show();
  const field = await open();
  fireEvent.change(field, { target: { value: "Private Old Draft" } });
  fireEvent.click(screen.getByRole("button", { name: "Post Reply" }));
  const next = { did: "did:plc:next" } as unknown as OAuthSession;
  const account = spyOn(auth, "useAuth").mockReturnValue({ session: { did: next.did }, getOAuthSession: () => next } as ReturnType<typeof auth.useAuth>);
  restores.push(() => account.mockRestore());
  view.rerender(<QueryClientProvider client={cache}><SocialReplyButton post={post} className="reply-action" moderation={{ ...moderation, userDid: next.did }} /></QueryClientProvider>);
  expect(() => captured.assertCurrentAccount!()).toThrow("account changed");
  expect(screen.queryByRole("dialog")).toBeNull();
  expect((await open()).value).toBe("");
  await act(async () => finish(result));
  expect(screen.getByRole("dialog")).toBeTruthy();
  expect(screen.queryByText("Reply Published")).toBeNull();
  expect(invalidate).not.toHaveBeenCalled();
});

it("masks the recipient handle when profile identity is withheld by moderation", async () => {
  const masked = { ...post, author: { ...post.author, labels: [{ src: "did:plc:labeler", uri: post.author.did, val: "!hide", cts: "2026-10-11T00:00:00Z" }] } };
  show(masked);
  await open();
  expect(screen.getByText("Replying To Account")).toBeTruthy();
  expect(screen.getByRole("dialog").textContent).not.toContain(post.author.handle);
});
