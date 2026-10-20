import type { AppBskyDraftDefs } from "@atproto/api";
import * as cloudDrafts from "@/lib/blueskyDraftClient";
import * as draftStorage from "@/lib/composerDraftStorage";
import * as gifs from "@/lib/klipyClient";
import type { GifAsset } from "@/lib/composerMedia";
import * as Pro from "@/hooks/useProEntitlements";
import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as scheduling from "@/hooks/useSkejScheduling";
import { localDateTimeValue } from "@/components/ContentCalendar/calendarDates";
import * as storedAuth from "@/lib/auth";
import * as brands from "@/hooks/useBrandAccounts";
import * as profiles from "@/lib/brandAccounts/brandAccountPublicProfile";
import * as social from "@/lib/blueskySocialClient";
import * as publishing from "@/lib/brandAccounts/brandAccountSocialClient";
import * as discovery from "@/lib/blueskySocialDiscoveryClient";
import * as compose from "@/lib/blueskyComposeClient";
import * as threads from "@/lib/blueskyThreadClient";
import * as ogPreview from "@/lib/latrSaveMetadataBackfill";
import { SocialComposeButton } from "@/components/Social/SocialComposeButton";

const restores: (() => void)[] = [];
let cache: QueryClient;
const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
let isPro = true;
let remoteDrafts: Map<string, AppBskyDraftDefs.DraftView>;
let localDrafts: Map<string, draftStorage.ComposerDraft>;
let draftNumber = 0;
function clone<T>(value: T): T { return structuredClone(value); }
function cloudView(id: string, draft: AppBskyDraftDefs.Draft): AppBskyDraftDefs.DraftView {
  return { id, draft: clone(draft), createdAt: "2026-10-20T15:00:00Z", updatedAt: "2026-10-20T15:00:00Z" };
}
beforeEach(() => {
  // Keep ownership until the asynchronous callback settles, just like Web Locks.
  const heldLocks = new Map<string, Promise<void>>();
  const request = async <T,>(name: string, options: LockOptions, callback: (lock: Lock | null) => T | PromiseLike<T>): Promise<T> => {
    options.signal?.throwIfAborted();
    if (options.mode && options.mode !== "exclusive") throw new Error("This test supports exclusive locks only");
    if (options.ifAvailable && heldLocks.has(name)) return await callback(null);
    while (heldLocks.has(name)) {
      await new Promise<void>((resolve, reject) => {
        const signal = options.signal;
        const abort = () => reject(signal?.reason);
        signal?.addEventListener("abort", abort, { once: true });
        void heldLocks.get(name)!.then(() => { signal?.removeEventListener("abort", abort); resolve(); });
      });
      options.signal?.throwIfAborted();
    }
    let release!: () => void;
    heldLocks.set(name, new Promise<void>(resolve => { release = resolve; }));
    try {
      // Aborting a granted request does not release it: its callback must finish.
      return await callback({ name, mode: "exclusive" } as Lock);
    } finally { heldLocks.delete(name); release(); }
  };
  const originalLocks = Object.getOwnPropertyDescriptor(navigator, "locks");
  Object.defineProperty(navigator, "locks", { configurable: true, value: { request: request as LockManager["request"] } });
  restores.push(() => { if (originalLocks) Object.defineProperty(navigator, "locks", originalLocks); else Reflect.deleteProperty(navigator, "locks"); });
  remoteDrafts = new Map(); localDrafts = new Map(); draftNumber = 0;
  const list = spyOn(cloudDrafts, "listSocialDrafts").mockImplementation(async () => ({ drafts: Array.from(remoteDrafts.values()).map(clone) }));
  const create = spyOn(cloudDrafts, "createSocialDraft").mockImplementation(async ({ draft }) => { const id = `draft-${++draftNumber}`; remoteDrafts.set(id, cloudView(id, draft)); return { id }; });
  const update = spyOn(cloudDrafts, "updateSocialDraft").mockImplementation(async ({ id, draft }) => { remoteDrafts.set(id, cloudView(id, draft)); });
  const remove = spyOn(cloudDrafts, "deleteSocialDraft").mockImplementation(async ({ id }) => { remoteDrafts.delete(id); });
  restores.push(() => list.mockRestore(), () => create.mockRestore(), () => update.mockRestore(), () => remove.mockRestore());
  const load = spyOn(draftStorage, "loadComposerDraft").mockImplementation(async (did, context) => clone(localDrafts.get(`${did}:${context}`)));
  const save = spyOn(draftStorage, "saveComposerDraft").mockImplementation(async (did, context, draft) => { const key = `${did}:${context}`; if (draft) localDrafts.set(key, clone(draft)); else localDrafts.delete(key); });
  restores.push(() => load.mockRestore(), () => save.mockRestore());
  isPro = true;
  const entitlement = spyOn(Pro, "useProEntitlements").mockImplementation(() => ({ isPro }) as ReturnType<typeof Pro.useProEntitlements>); restores.push(() => entitlement.mockRestore());
  const scheduler = spyOn(scheduling, "useSkejScheduling").mockReturnValue({ readiness: { data: { accountDid: oauth.did, connected: true }, isPending: false, isError: false, refetch: async () => ({}) }, schedules: {}, pending: false, schedule: async () => ({}), cancel: async () => {}, reschedule: async () => {}, connectUrl: "https://skej.test/connect" } as unknown as ReturnType<typeof scheduling.useSkejScheduling>); restores.push(() => scheduler.mockRestore());
  const stored = spyOn(storedAuth, "getStoredOAuthDid").mockReturnValue(oauth.did); restores.push(() => stored.mockRestore());
  const linked = spyOn(brands, "useBrandAccounts").mockReturnValue([]); restores.push(() => linked.mockRestore());
  const profile = spyOn(profiles, "getBrandAccountPublicProfile").mockImplementation(async did => ({ did, handle: did === oauth.did ? "viewer.test" : "brand.test", displayName: did === oauth.did ? "Personal" : "Brand" })); restores.push(() => profile.mockRestore());
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const spy = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession: () => oauth } as ReturnType<typeof auth.useAuth>);
  restores.push(() => spy.mockRestore());
  const values = { localStorage: window.localStorage, DOMRect: window.DOMRect, Element: window.Element, HTMLElement: window.HTMLElement, Node: window.Node, MutationObserver: window.MutationObserver, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout };
  for (const [name, value] of Object.entries(values)) {
    const original = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (original) Object.defineProperty(globalThis, name, original); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(async () => { await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); }); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
async function open() {
  render(<QueryClientProvider client={cache}><SocialComposeButton /></QueryClientProvider>);
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  return await loadedField();
}

async function loadedField() {
  await screen.findByRole("textbox", { name: "Post Text" });
  await waitFor(() => expect(screen.getByRole("textbox", { name: "Post Text" }).hasAttribute("disabled")).toBe(false));
  return screen.getByRole("textbox", { name: "Post Text" }) as HTMLTextAreaElement;
}
async function resumeSavedDraft() {
  const saved = Array.from(remoteDrafts.values())[0];
  expect(saved).toBeDefined();
  cleanup();
  render(<QueryClientProvider client={cache}><SocialComposeButton initialDraft={clone(saved)} autoOpen hideTrigger /></QueryClientProvider>);
  return await loadedField();
}

const gifAsset: GifAsset = { id: "123", title: "Celebrate", description: "A celebration", url: "https://static.klipy.com/ii/example/full.gif", poster: "https://static.klipy.com/ii/example/still.jpg", mp4: "https://static.klipy.com/ii/example/video.mp4", width: 280, height: 498, attribution: "Powered by KLIPY" };
it("allows a GIF-only post only after explicitly acknowledging missing descriptions", async () => {
  const search = spyOn(gifs, "getComposerGifs").mockResolvedValue({ results: [gifAsset], next: "" });
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: `at://${oauth.did}/app.bsky.feed.post/new`, cid: "cid" });
  restores.push(() => search.mockRestore(), () => publish.mockRestore());
  await open();
  fireEvent.click(screen.getByRole("button", { name: "GIF" }));
  fireEvent.click(await screen.findByRole("button", { name: "Select GIF: A celebration" }));
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  expect(publish).not.toHaveBeenCalled();
  fireEvent.click(await screen.findByRole("button", { name: "Post Without Descriptions" }));
  await screen.findByText("Post Published");
  expect(publish.mock.calls[0][0]).toMatchObject({ text: "", media: { kind: "gif", asset: { id: "123" } } });
});

it("keeps GIFs and edited alt text on their original segment when a thread is reordered", async () => {
  const search = spyOn(gifs, "getComposerGifs").mockResolvedValue({ results: [gifAsset], next: "" });
  const publish = spyOn(threads, "publishBlueskyThread").mockResolvedValue([]);
  restores.push(() => search.mockRestore(), () => publish.mockRestore());
  await open();
  fireEvent.click(screen.getByRole("button", { name: "GIF" }));
  fireEvent.click(await screen.findByRole("button", { name: "Select GIF: A celebration" }));
  fireEvent.click(screen.getByRole("button", { name: "Add Alt Text" }));
  fireEvent.change(await screen.findByRole("textbox", { name: "Alt Text" }), { target: { value: "A person celebrates a win" } });
  fireEvent.click(screen.getByRole("button", { name: "Save Description" }));
  fireEvent.click(screen.getByRole("button", { name: "Add Post" }));
  fireEvent.change(screen.getByRole("textbox", { name: "Post 2 Text" }), { target: { value: "Second segment" } });
  fireEvent.click(screen.getByRole("button", { name: "Move Post 1 Down" }));
  fireEvent.click(screen.getByRole("button", { name: "Post Thread" }));
  await waitFor(() => expect(publish).toHaveBeenCalledTimes(1));
  const segments = publish.mock.calls[0][0].publication.segments;
  expect(segments[0].draft).toMatchObject({ text: "Second segment" });
  expect(segments[0].draft.media).toBeUndefined();
  expect(segments[1].draft).toMatchObject({ media: { kind: "gif", alt: "A person celebrates a win", asset: { id: "123" } } });
});

it("opens from the floating button and publishes only on explicit submission", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: `at://${oauth.did}/app.bsky.feed.post/new`, cid: "cid" });
  const invalidate = spyOn(cache, "invalidateQueries");
  restores.push(() => publish.mockRestore(), () => invalidate.mockRestore());
  let dismissToast: (() => void) | undefined;
  const originalTimeout = globalThis.setTimeout;
  globalThis.setTimeout = ((callback: TimerHandler, delay?: number, ...args: unknown[]) => {
    if (delay === 3300 && typeof callback === "function") {
      dismissToast = callback as () => void;
      return originalTimeout(() => {}, 0);
    }
    return originalTimeout(callback, delay, ...args);
  }) as typeof setTimeout;
  restores.push(() => { globalThis.setTimeout = originalTimeout; });
  const field = await open();
  expect(publish).not.toHaveBeenCalled();
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(true);
  fireEvent.change(field, { target: { value: "Hello #Bluesky" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await screen.findByText("Post Published");
  expect(publish).toHaveBeenCalledTimes(1);
  expect(publish.mock.calls[0][0].text).toBe("Hello #Bluesky");
  expect(publish.mock.calls[0][0].session).toBe(oauth);
  expect(invalidate).toHaveBeenCalled();
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(screen.getByRole("status").className).toContain("[animation-delay:3s]");
  expect(dismissToast).toBeDefined();
  await act(async () => dismissToast!());
  expect(screen.queryByText("Post Published")).toBeNull();
});

it.each(["metaKey", "ctrlKey"] as const)("publishes with the %s Enter composer shortcut while respecting invalid drafts and plain Enter", async modifier => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: `at://${oauth.did}/app.bsky.feed.post/new`, cid: "cid" });
  restores.push(() => publish.mockRestore());
  const field = await open();
  fireEvent.keyDown(field, { key: "Enter", [modifier]: true });
  expect(publish).not.toHaveBeenCalled();
  fireEvent.change(field, { target: { value: "Keyboard Published Post" } });
  fireEvent.keyDown(field, { key: "Enter" });
  fireEvent.keyDown(field, { key: "Enter", [modifier]: true, isComposing: true });
  fireEvent.keyDown(field, { key: "Enter", [modifier]: true, repeat: true });
  expect(publish).not.toHaveBeenCalled();
  fireEvent.keyDown(field, { key: "Enter", [modifier]: true });
  await screen.findByText("Post Published");
  expect(publish).toHaveBeenCalledTimes(1);
  expect(publish.mock.calls[0][0].text).toBe("Keyboard Published Post");
  expect(publish.mock.calls[0][0].session).toBe(oauth);
});

it("enforces grapheme limits and saves cancelled content separately from a fresh new compose", async () => {
  const field = await open();
  fireEvent.change(field, { target: { value: "👨‍👩‍👧‍👦".repeat(300) } });
  // This also exceeds the native byte limit even though the visible character count is valid.
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(true);
  fireEvent.change(field, { target: { value: "a".repeat(301) } });
  expect(screen.getByText("301/300")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  expect((await loadedField()).value).toBe("");
  expect(Array.from(remoteDrafts.values())[0].draft.posts[0].text).toBe("a".repeat(301));
});

it("preserves content on failure and allows retry", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockRejectedValue(new Error("Post failed"));
  restores.push(() => publish.mockRestore());
  const field = await open();
  fireEvent.change(field, { target: { value: "Keep this draft" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("Your post could not be published. Please try again."));
  expect((field as HTMLTextAreaElement).value).toBe("Keep this draft");
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(false);
});

it("prevents duplicate submission and closing while a post is pending", async () => {
  let resolve!: (value: { uri: string; cid: string }) => void;
  const publish = spyOn(compose, "createBlueskyPost").mockReturnValue(new Promise(complete => { resolve = complete; }));
  restores.push(() => publish.mockRestore());
  const field = await open();
  fireEvent.change(field, { target: { value: "Once" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  expect(screen.getByRole("button", { name: "Publishing…" }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("button", { name: "Cancel" }).hasAttribute("disabled")).toBe(true);
  await waitFor(() => expect(publish).toHaveBeenCalledTimes(1));
  await act(async () => resolve({ uri: "at://did:plc:viewer/app.bsky.feed.post/new", cid: "cid" }));
});

it("publishes and resolves mentions as the selected brand without replacing personal auth", async () => {
  const brand = { did: "did:plc:brand" } as unknown as OAuthSession;
  const linked = spyOn(brands, "useBrandAccounts").mockReturnValue([brand.did]); restores.push(() => linked.mockRestore());
  let allowed = true;
  const connection = spyOn(brands, "useBrandAccountSession").mockReturnValue({ session: brand, error: undefined, generation: 0, retry: () => {}, assertCurrentActor: () => { if (!allowed) throw new Error("Account Changed"); } }); restores.push(() => connection.mockRestore());
  const moderation = { userDid: brand.did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
  const catalog = spyOn(social, "getBlueskySocialCatalog").mockResolvedValue({ moderation, feeds: [] } as Awaited<ReturnType<typeof social.getBlueskySocialCatalog>>); restores.push(() => catalog.mockRestore());
  const agent = spyOn(social, "createAuthenticatedAppViewAgent").mockReturnValue({ app: { bsky: { actor: { getProfile: async () => ({ data: { did: brand.did, handle: "brand.test", displayName: "Brand" } }) } } } } as ReturnType<typeof social.createAuthenticatedAppViewAgent>); restores.push(() => agent.mockRestore());
  const people = spyOn(discovery, "getSocialExplorePage").mockResolvedValue({ posts: [], actors: [{ did: "did:plc:person", handle: "person.test" }] }); restores.push(() => people.mockRestore());
  const post = spyOn(publishing, "publishBrandPost").mockImplementation(async args => { args.assertCurrentActor(); return { uri: "at://did:plc:brand/app.bsky.feed.post/new", cid: "cid" }; }); restores.push(() => post.mockRestore());
  const personal = spyOn(compose, "createBlueskyPost"); restores.push(() => personal.mockRestore());
  await open();
  const picker = screen.getByRole("combobox", { name: "Post As" });
  expect((picker as HTMLSelectElement).value).toBe(oauth.did);
  fireEvent.change(picker, { target: { value: brand.did } });
  const field = await screen.findByRole("textbox", { name: "Brand Post Text" });
  fireEvent.change(field, { target: { value: "Hi @person", selectionStart: 10 } });
  fireEvent.click(await screen.findByRole("option", { name: "@person.test" }));
  expect(people.mock.calls[0][0].session).toBe(brand);
  allowed = false;
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await screen.findByRole("alert");
  expect(post).not.toHaveBeenCalled();
  allowed = true;
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(post.mock.calls[0][0].session).toBe(brand);
  expect(personal).not.toHaveBeenCalled();
  expect(auth.useAuth().getOAuthSession()).toBe(oauth);
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  expect((screen.getByRole("combobox", { name: "Post As" }) as HTMLSelectElement).value).toBe(oauth.did);
  const schedule = mockSchedule();
  fireEvent.change(screen.getByRole("combobox", { name: "Post As" }), { target: { value: brand.did } });
  fireEvent.change(await screen.findByRole("textbox", { name: "Brand Post Text" }), { target: { value: "Brand Scheduled" } });
  fireEvent.click(screen.getByRole("button", { name: "Schedule" }));
  const value = localDateTimeValue(new Date(Date.now() + 3_600_000));
  fireEvent.change(screen.getByLabelText("Publish At"), { target: { value } });
  fireEvent.click(screen.getByRole("button", { name: "Schedule Post" }));
  await screen.findByText("Post Scheduled");
  expect(schedule).toHaveBeenCalledWith("Brand Scheduled", new Date(value).toISOString(), undefined);
  expect(scheduling.useSkejScheduling).toHaveBeenCalledWith(oauth.did, brand.did, { includeSchedules: false });
  expect(post).toHaveBeenCalledTimes(1);
}, 15_000);

it("isolates personal drafts and pending guards when the owner changes", async () => {
  let captured: Parameters<typeof compose.createBlueskyPost>[0] | undefined;
  let finish!: (result: { uri: string; cid: string }) => void;
  const publish = spyOn(compose, "createBlueskyPost").mockImplementation(args => { captured = args; return new Promise(resolve => { finish = resolve; }); }); restores.push(() => publish.mockRestore());
  const view = render(<QueryClientProvider client={cache}><SocialComposeButton /></QueryClientProvider>);
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  fireEvent.change(await loadedField(), { target: { value: "Private Old Draft" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await waitFor(() => expect(captured).toBeDefined());
  const next = { did: "did:plc:next" } as unknown as OAuthSession;
  spyOn(auth, "useAuth").mockReturnValue({ session: { did: next.did }, getOAuthSession: () => next } as ReturnType<typeof auth.useAuth>);
  view.rerender(<QueryClientProvider client={cache}><SocialComposeButton /></QueryClientProvider>);
  expect(() => captured!.assertCurrentAccount!()).toThrow("account changed");
  expect(screen.queryByRole("dialog")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  expect((await screen.findByRole("textbox", { name: "Post Text" }) as HTMLTextAreaElement).value).toBe("");
  await act(async () => finish({ uri: "at://did:plc:viewer/app.bsky.feed.post/new", cid: "cid" }));
  expect(screen.getByRole("dialog")).toBeTruthy();
  expect(screen.queryByText("Post Published")).toBeNull();
});

function mockSchedule() {
  const schedule = mock(async () => ({}));
  const previous = scheduling.useSkejScheduling(oauth.did, oauth.did);
  spyOn(scheduling, "useSkejScheduling").mockReturnValue({ ...previous, schedule } as unknown as ReturnType<typeof scheduling.useSkejScheduling>);
  return schedule;
}
it("queues personal posts in Skej rather than publishing immediately", async () => {
  const schedule = mockSchedule();
  const publish = spyOn(compose, "createBlueskyPost"); restores.push(() => publish.mockRestore());
  fireEvent.change(await open(), { target: { value: "Scheduled Content" } });
  fireEvent.click(screen.getByRole("button", { name: "Schedule" }));
  expect(screen.getByRole("button", { name: "Schedule Post" }).hasAttribute("disabled")).toBe(true);
  const value = localDateTimeValue(new Date(Date.now() + 3_600_000));
  fireEvent.change(screen.getByLabelText("Publish At"), { target: { value } });
  fireEvent.click(screen.getByRole("button", { name: "Schedule Post" }));
  await screen.findByText("Post Scheduled");
  expect(schedule).toHaveBeenCalledWith("Scheduled Content", new Date(value).toISOString(), undefined);
  expect(publish).not.toHaveBeenCalled();
});

it("keeps Free composition personal and offers no scheduling controls", async () => {
  isPro = false;
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: `at://${oauth.did}/app.bsky.feed.post/free`, cid: "cid" }); restores.push(() => publish.mockRestore());
  const brandPublish = spyOn(publishing, "publishBrandPost"); restores.push(() => brandPublish.mockRestore());
  const field = await open();
  expect((screen.getByRole("combobox", { name: "Post As" }) as HTMLSelectElement).value).toBe(oauth.did);
  expect(screen.getAllByRole("option")).toHaveLength(1);
  expect(screen.queryByRole("button", { name: "Schedule" })).toBeNull();
  expect(screen.getByText("Multi-account support and scheduling require Pro.")).toBeTruthy();
  fireEvent.change(field, { target: { value: "Personal Free Post" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await screen.findByText("Post Published");
  expect(publish.mock.calls[0][0].session).toBe(oauth);
  expect(brandPublish).not.toHaveBeenCalled();
});
it("drops a selected brand composer after downgrade without publishing its draft", async () => {
  const brand = { did: "did:plc:brand" } as unknown as OAuthSession;
  const linked = spyOn(brands, "useBrandAccounts").mockImplementation(() => isPro ? [brand.did] : []); restores.push(() => linked.mockRestore());
  const connection = spyOn(brands, "useBrandAccountSession").mockReturnValue({ session: brand, error: undefined, generation: 0, retry: () => {}, assertCurrentActor: () => {} }); restores.push(() => connection.mockRestore());
  const catalog = spyOn(social, "getBlueskySocialCatalog").mockResolvedValue({ moderation: { userDid: brand.did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } }, feeds: [] } as Awaited<ReturnType<typeof social.getBlueskySocialCatalog>>); restores.push(() => catalog.mockRestore());
  const agent = spyOn(social, "createAuthenticatedAppViewAgent").mockReturnValue({ app: { bsky: { actor: { getProfile: async () => ({ data: { did: brand.did, handle: "brand.test", displayName: "Brand" } }) } } } } as ReturnType<typeof social.createAuthenticatedAppViewAgent>); restores.push(() => agent.mockRestore());
  const brandPublish = spyOn(publishing, "publishBrandPost"); restores.push(() => brandPublish.mockRestore());
  const personalPublish = spyOn(compose, "createBlueskyPost"); restores.push(() => personalPublish.mockRestore());
  const view = render(<QueryClientProvider client={cache}><SocialComposeButton /></QueryClientProvider>);
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  fireEvent.change(screen.getByRole("combobox", { name: "Post As" }), { target: { value: brand.did } });
  fireEvent.change(await screen.findByRole("textbox", { name: "Brand Post Text" }), { target: { value: "Private Brand Draft" } });
  isPro = false;
  view.rerender(<QueryClientProvider client={cache}><SocialComposeButton /></QueryClientProvider>);
  expect(screen.queryByRole("textbox", { name: "Brand Post Text" })).toBeNull();
  expect((screen.getByRole("combobox", { name: "Post As" }) as HTMLSelectElement).value).toBe(oauth.did);
  expect((screen.getByRole("textbox", { name: "Post Text" }) as HTMLTextAreaElement).value).toBe("");
  expect(screen.queryByRole("button", { name: "Schedule" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  expect(brandPublish).not.toHaveBeenCalled();
  expect(personalPublish).not.toHaveBeenCalled();
});

it("previews pasted links without posting and preserves explicit removal through submission", async () => {
  const metadata = spyOn(ogPreview, "fetchLatrOgPreview").mockResolvedValue({ title: "Article Title", excerpt: "Article Summary" });
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: "at://did:plc:viewer/app.bsky.feed.post/new", cid: "cid" });
  restores.push(() => metadata.mockRestore(), () => publish.mockRestore());
  const field = await open();
  fireEvent.change(field, { target: { value: "Read https://example.com/story" } });
  await screen.findByText("Article Title");
  expect(screen.getAllByRole("region", { name: "Link Preview" })).toHaveLength(1);
  expect(screen.getByText("Article Summary")).toBeTruthy();
  expect(publish).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Remove Link Preview" }));
  fireEvent.change(field, { target: { value: "Please read https://example.com/story" } });
  expect(screen.queryByRole("region", { name: "Link Preview" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await screen.findByText("Post Published");
  expect(publish.mock.calls[0][0].linkPreview).toBeUndefined();
});

it("ignores stale metadata and publishes only the replacement link card", async () => {
  let finishOld!: (value: { title: string }) => void;
  const old = new Promise<{ title: string }>(resolve => { finishOld = resolve; });
  const metadata = spyOn(ogPreview, "fetchLatrOgPreview").mockImplementation(async (_session, url) => url.endsWith("/old") ? old : { title: "Replacement", excerpt: "New Summary" });
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: "at://did:plc:viewer/app.bsky.feed.post/new", cid: "cid" });
  restores.push(() => metadata.mockRestore(), () => publish.mockRestore());
  const field = await open();
  fireEvent.change(field, { target: { value: "https://example.com/old" } });
  await waitFor(() => expect(metadata).toHaveBeenCalled());
  fireEvent.change(field, { target: { value: "https://example.com/new" } });
  await screen.findByText("Replacement");
  await act(async () => finishOld({ title: "Stale Article" }));
  expect(screen.queryByText("Stale Article")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await screen.findByText("Post Published");
  expect(publish.mock.calls[0][0].linkPreview).toMatchObject({ uri: "https://example.com/new", title: "Replacement", description: "New Summary" });
});

it("keeps text-only posting available when metadata fails", async () => {
  const metadata = spyOn(ogPreview, "fetchLatrOgPreview").mockResolvedValue(null);
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: "at://did:plc:viewer/app.bsky.feed.post/new", cid: "cid" });
  restores.push(() => metadata.mockRestore(), () => publish.mockRestore());
  const field = await open();
  fireEvent.change(field, { target: { value: "https://example.com/unavailable" } });
  await screen.findByText("Link Preview Unavailable. You Can Still Post the Link.");
  expect(publish).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await screen.findByText("Post Published");
  expect(publish).toHaveBeenCalledTimes(1);
  expect(publish.mock.calls[0][0].linkPreview).toBeUndefined();
});

it("waits for the pasted link's metadata when Post is clicked before the preview finishes", async () => {
  let finish!: (value: { title: string; excerpt: string }) => void;
  const deferred = new Promise<{ title: string; excerpt: string }>(resolve => { finish = resolve; });
  const metadata = spyOn(ogPreview, "fetchLatrOgPreview").mockReturnValue(deferred);
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: "at://did:plc:viewer/app.bsky.feed.post/new", cid: "cid" });
  restores.push(() => metadata.mockRestore(), () => publish.mockRestore());
  const field = await open();
  fireEvent.change(field, { target: { value: "https://example.com/quick" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await waitFor(() => expect(metadata).toHaveBeenCalledTimes(1));
  expect(publish).not.toHaveBeenCalled();
  expect(screen.getByRole("button", { name: "Publishing…" }).hasAttribute("disabled")).toBe(true);
  await act(async () => finish({ title: "Quick Story", excerpt: "Summary" }));
  await screen.findByText("Post Published");
  expect(publish).toHaveBeenCalledTimes(1);
  expect(publish.mock.calls[0][0].linkPreview).toMatchObject({ uri: "https://example.com/quick", title: "Quick Story" });
});


it("adds, edits, reorders and deletes thread segments with per-post limits", async () => {
  const field = await open();
  fireEvent.change(field, { target: { value: "First Segment" } });
  fireEvent.click(screen.getByRole("button", { name: "Add Post" }));
  expect(screen.getByRole("button", { name: "Post Thread" }).hasAttribute("disabled")).toBe(true);
  const second = screen.getByRole("textbox", { name: "Post 2 Text" });
  fireEvent.change(second, { target: { value: "b".repeat(301) } });
  expect(screen.getByRole("button", { name: "Post Thread" }).hasAttribute("disabled")).toBe(true);
  fireEvent.change(second, { target: { value: "Second Segment" } });
  expect(screen.getByRole("button", { name: "Post Thread" }).hasAttribute("disabled")).toBe(false);
  fireEvent.click(screen.getByRole("button", { name: "Move Post 2 Up" }));
  expect((screen.getByRole("textbox", { name: "Post Text" }) as HTMLTextAreaElement).value).toBe("Second Segment");
  expect((screen.getByRole("textbox", { name: "Post 2 Text" }) as HTMLTextAreaElement).value).toBe("First Segment");
  fireEvent.click(screen.getByRole("button", { name: "Delete Post 2" }));
  expect(screen.queryByRole("textbox", { name: "Post 2 Text" })).toBeNull();
  expect(screen.getByRole("button", { name: "Post" })).toBeTruthy();
});

it("preserves a thread on dismissal and retries its original publication after partial failure", async () => {
  const calls: Parameters<typeof threads.publishBlueskyThread>[0][] = [];
  const publish = spyOn(threads, "publishBlueskyThread").mockImplementation(async args => {
    calls.push(args);
    args.onProgress?.(1);
    args.publication.segments[0].attempted = true;
    if (calls.length === 1) throw new Error("Second Post Failed");
    return [];
  });
  restores.push(() => publish.mockRestore());
  fireEvent.change(await open(), { target: { value: "Thread Root" } });
  fireEvent.click(screen.getByRole("button", { name: "Add Post" }));
  fireEvent.change(screen.getByRole("textbox", { name: "Post 2 Text" }), { target: { value: "Thread Reply" } });
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  await resumeSavedDraft();
  expect((screen.getByRole("textbox", { name: "Post 2 Text" }) as HTMLTextAreaElement).value).toBe("Thread Reply");
  fireEvent.click(screen.getByRole("button", { name: "Post Thread" }));
  await screen.findByRole("alert");
  expect(screen.getByText("1 of 2 Posts Published. Retry Continues This Thread.")).toBeTruthy();
  expect(screen.getByRole("textbox", { name: "Post Text" }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("button", { name: "Add Post" }).hasAttribute("disabled")).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Retry Remaining Posts" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(calls).toHaveLength(2);
  expect(calls[0].publication).toBe(calls[1].publication);
  expect(calls[0].publication.segments.map(segment => segment.draft.text)).toEqual(["Thread Root", "Thread Reply"]);
}, 15_000);


it("preserves removed segment cards across dismissal and unlocks a thread that failed before any write", async () => {
  const metadata = spyOn(ogPreview, "fetchLatrOgPreview").mockResolvedValue({ title: "Dismissed Card", excerpt: "Summary" });
  const publish = spyOn(threads, "publishBlueskyThread").mockRejectedValue(new Error("Preparation Failed"));
  restores.push(() => metadata.mockRestore(), () => publish.mockRestore());
  fireEvent.change(await open(), { target: { value: "https://example.com/draft" } });
  await screen.findByText("Dismissed Card");
  fireEvent.click(screen.getByRole("button", { name: "Remove Link Preview" }));
  fireEvent.click(screen.getByRole("button", { name: "Add Post" }));
  fireEvent.change(screen.getByRole("textbox", { name: "Post 2 Text" }), { target: { value: "Second Post" } });
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  await resumeSavedDraft();
  expect(screen.queryByText("Dismissed Card")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Post Thread" }));
  await screen.findByRole("alert");
  expect(publish.mock.calls[0][0].publication.segments[0].draft.linkPreview).toBeUndefined();
  expect(screen.getByRole("textbox", { name: "Post Text" }).hasAttribute("disabled")).toBe(false);
  expect(screen.getByRole("button", { name: "Add Post" }).hasAttribute("disabled")).toBe(false);
});

it("resumes a cloud draft, autosaves edits on close, and starts a separate blank post", async () => {
  const initial = cloudView("resume", { posts: [{ text: "Saved cloud text" }] });
  remoteDrafts.set(initial.id, initial);
  const changed = mock(() => {});
  const view = render(<QueryClientProvider client={cache}><SocialComposeButton initialDraft={initial} autoOpen hideTrigger onDraftChanged={changed} /></QueryClientProvider>);
  fireEvent.change(await loadedField(), { target: { value: "Edited saved cloud text" } });
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(remoteDrafts.get(initial.id)?.draft.posts[0].text).toBe("Edited saved cloud text");
  expect(remoteDrafts.size).toBe(1);
  expect(changed).toHaveBeenCalled();
  view.rerender(<QueryClientProvider client={cache}><SocialComposeButton /></QueryClientProvider>);
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  expect((await loadedField()).value).toBe("");
});

it("blocks unavailable media from publishing until the user explicitly removes it", async () => {
  const initial = cloudView("media", { posts: [{ text: "Text with device media", embedImages: [{ localRef: { path: "original-device/photo" }, alt: "Photo" }], embedVideos: [{ localRef: { path: "original-device/video" } }] }] });
  remoteDrafts.set(initial.id, initial);
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: "at://did:plc:viewer/app.bsky.feed.post/media", cid: "cid" });
  restores.push(() => publish.mockRestore());
  render(<QueryClientProvider client={cache}><SocialComposeButton initialDraft={initial} autoOpen hideTrigger /></QueryClientProvider>);
  await loadedField();
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  expect(publish).not.toHaveBeenCalled();
  expect(remoteDrafts.get(initial.id)?.draft.posts[0].embedImages).toHaveLength(1);
  fireEvent.click(screen.getByRole("button", { name: "Remove Unavailable Attachments" }));
  await waitFor(() => expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(false));
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await screen.findByText("Post Published");
  expect(publish).toHaveBeenCalledTimes(1);
  expect(publish.mock.calls[0][0]).toMatchObject({ text: "Text with device media" });
  expect(publish.mock.calls[0][0].media).toBeUndefined();
});

const unsupportedSettings: Partial<AppBskyDraftDefs.Draft>[] = [
  { threadgateAllow: [] },
  { postgateEmbeddingRules: [] },
  { langs: ["fr"] },
  { posts: [{ text: "Foreign labeled draft", labels: { $type: "com.atproto.label.defs#selfLabels", values: [{ val: "sexual" }] } }] },
  { posts: [{ text: "Foreign quote", embedRecords: [{ record: { uri: "at://did:plc:other/app.bsky.feed.post/one", cid: "bafyreia" } }] }] },
];
it.each(unsupportedSettings)("preserves unsupported foreign draft settings and prevents publishing: %j", async settings => {
  const initial = cloudView("foreign", { posts: [{ text: "Foreign draft" }], ...settings });
  remoteDrafts.set(initial.id, initial);
  const publish = spyOn(compose, "createBlueskyPost");
  restores.push(() => publish.mockRestore());
  render(<QueryClientProvider client={cache}><SocialComposeButton initialDraft={initial} autoOpen hideTrigger /></QueryClientProvider>);
  const field = await loadedField();
  expect(screen.getByText("This Draft Has Quote, Language, Content Label, or Audience Settings That This Composer Cannot Publish Yet. Continue in the Original App to Keep Those Settings.")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(true);
  fireEvent.keyDown(field, { key: "Enter", metaKey: true });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  expect(publish).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(remoteDrafts.get(initial.id)?.draft).toMatchObject(initial.draft);
});

it("retries failed draft cleanup without publishing the successful post again", async () => {
  const initial = cloudView("cleanup", { posts: [{ text: "Publish only once" }] });
  remoteDrafts.set(initial.id, initial);
  const remove = spyOn(cloudDrafts, "deleteSocialDraft").mockRejectedValue(new Error("Cleanup unavailable"));
  const publish = spyOn(compose, "createBlueskyPost").mockImplementation(async args => {
    const item = args.publication!.segments[0];
    item.attempted = true;
    item.result = { uri: "at://did:plc:viewer/app.bsky.feed.post/once", cid: "cid" };
    await args.checkpoint?.();
    return item.result;
  });
  restores.push(() => remove.mockRestore(), () => publish.mockRestore());
  render(<QueryClientProvider client={cache}><SocialComposeButton initialDraft={initial} autoOpen hideTrigger /></QueryClientProvider>);
  await loadedField();
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await screen.findByRole("button", { name: "Finish Draft Cleanup" });
  expect(publish).toHaveBeenCalledTimes(1);
  const submit = screen.getByRole("button", { name: "Post" });
  expect(submit.hasAttribute("disabled")).toBe(true);
  fireEvent.click(submit);
  remove.mockResolvedValue(undefined);
  fireEvent.click(screen.getByRole("button", { name: "Finish Draft Cleanup" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(remove).toHaveBeenCalledTimes(2);
  expect(publish).toHaveBeenCalledTimes(1);
});

it("holds the account's exclusive edit lock until unmount and permits the next composer afterward", async () => {
  await open();
  const name = `the-social-wire.social-composer:${oauth.did}`;
  expect(await navigator.locks.request(name, { mode: "exclusive", ifAvailable: true }, lock => lock !== null)).toBe(false);
  await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); });
  expect(await navigator.locks.request(name, { mode: "exclusive", ifAvailable: true }, lock => lock !== null)).toBe(true);
  expect((await open()).value).toBe("");
});
