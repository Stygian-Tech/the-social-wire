import * as draftStorage from "@/lib/composerDraftStorage";
import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as storedAuth from "@/lib/auth";
import * as compose from "@/lib/blueskyComposeClient";
import * as refresh from "@/lib/socialPostRefresh";
import { DialogTrigger } from "@/components/ui/dialog";
import { SocialPostComposeDialog } from "@/components/Social/SocialPostComposeDialog";

const restores: (() => void)[] = [];
let cache: QueryClient;
const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
const moderation: ModerationOpts = { userDid: oauth.did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const post: AppBskyFeedDefs.PostView = { uri: "at://did:plc:alice/app.bsky.feed.post/one", cid: "bafyreia", author: { did: "did:plc:alice", handle: "alice.test" }, record: { $type: "app.bsky.feed.post", text: "Hello", createdAt: "2026-10-11T12:00:00Z" }, indexedAt: "2026-10-11T12:00:00Z" };
beforeEach(() => {
  const load = spyOn(draftStorage, "loadComposerDraft").mockResolvedValue(undefined);
  const save = spyOn(draftStorage, "saveComposerDraft").mockResolvedValue(undefined);
  restores.push(() => load.mockRestore(), () => save.mockRestore());
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const spies = [spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession: () => oauth } as ReturnType<typeof auth.useAuth>), spyOn(storedAuth, "getStoredOAuthDid").mockReturnValue(oauth.did)];
  restores.push(...spies.map(spy => () => spy.mockRestore()));
  for (const [name, value] of Object.entries({ getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0), cancelAnimationFrame: clearTimeout })) {
    const original = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (original) Object.defineProperty(globalThis, name, original); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });

async function open(mode: "reply" | "quote") {
  const view = render(<QueryClientProvider client={cache}><SocialPostComposeDialog post={post} moderation={moderation} mode={mode} trigger={() => <DialogTrigger>Compose</DialogTrigger>} /></QueryClientProvider>);
  fireEvent.click(screen.getByRole("button", { name: "Compose" }));
  const field = await screen.findByRole("textbox", { name: mode === "reply" ? "Reply Text" : "Quote Text" });
  return { view, field };
}

it("restores reply drafts only when the composer opens, without loading every feed card's draft", async () => {
  const load = spyOn(draftStorage, "loadComposerDraft");
  render(<QueryClientProvider client={cache}><SocialPostComposeDialog post={post} moderation={moderation} mode="reply" trigger={() => <DialogTrigger>Compose</DialogTrigger>} /></QueryClientProvider>);
  expect(load).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Compose" }));
  await waitFor(() => expect(load).toHaveBeenCalledTimes(1));
});

it.each(["reply", "quote"] as const)("previews native %s text and refreshes only after publishing", async mode => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: "at://did:plc:viewer/app.bsky.feed.post/new", cid: "bafyreia" });
  let stopped = false;
  const reload = spyOn(refresh, "refreshSocialPostQueries").mockReturnValue(() => { stopped = true; });
  restores.push(() => publish.mockRestore(), () => reload.mockRestore());
  const { view, field } = await open(mode);
  fireEvent.change(field, { target: { value: "**Formatted** *draft*" } });
  expect(screen.getByRole("region", { name: "Post Preview" }).textContent).toBe("PreviewFormatted draft");
  expect(reload).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: mode === "reply" ? "Post Reply" : "Post Quote" }));
  await waitFor(() => expect(reload).toHaveBeenCalledTimes(1));
  expect(reload.mock.calls[0][1]).toBe(oauth.did);
  expect(reload.mock.calls[0][2]()).toBe(true);
  expect(publish.mock.calls[0][0].text).toBe("**Formatted** *draft*");
  expect(publish.mock.calls[0][0][mode === "reply" ? "replyTo" : "quoteTo"]).toBe(post);
  view.unmount();
  expect(stopped).toBe(true);
  expect(reload.mock.calls[0][2]()).toBe(false);
});

it("keeps the formatted draft and skips refresh when posting fails", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockRejectedValue(new Error("Posting Failed"));
  const reload = spyOn(refresh, "refreshSocialPostQueries");
  restores.push(() => publish.mockRestore(), () => reload.mockRestore());
  const { field } = await open("reply");
  fireEvent.change(field, { target: { value: "**Keep Me**" } });
  fireEvent.click(screen.getByRole("button", { name: "Post Reply" }));
  await screen.findByRole("alert");
  expect((field as HTMLTextAreaElement).value).toBe("**Keep Me**");
  expect(screen.getByRole("region", { name: "Post Preview" }).textContent).toBe("PreviewKeep Me");
  expect(reload).not.toHaveBeenCalled();
});

it.each(["reply", "quote"] as const)("submits a %s with the keyboard shortcut and blocks duplicate pending submissions", async mode => {
  let finish!: (value: { uri: string; cid: string }) => void;
  const publish = spyOn(compose, "createBlueskyPost").mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  const reload = spyOn(refresh, "refreshSocialPostQueries").mockReturnValue(() => {});
  restores.push(() => publish.mockRestore(), () => reload.mockRestore());
  const { field } = await open(mode);
  fireEvent.change(field, { target: { value: "Keyboard Reply Or Quote" } });
  fireEvent.keyDown(field, { key: "Enter", ctrlKey: true });
  fireEvent.keyDown(field, { key: "Enter", metaKey: true });
  await waitFor(() => expect(publish).toHaveBeenCalledTimes(1));
  expect(publish.mock.calls[0][0][mode === "reply" ? "replyTo" : "quoteTo"]).toBe(post);
  await act(async () => finish({ uri: "at://did:plc:viewer/app.bsky.feed.post/new", cid: "cid" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
});
