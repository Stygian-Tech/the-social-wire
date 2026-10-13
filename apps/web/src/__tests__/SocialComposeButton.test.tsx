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
import * as ogPreview from "@/lib/latrSaveMetadataBackfill";
import { SocialComposeButton } from "@/components/Social/SocialComposeButton";

const restores: (() => void)[] = [];
let cache: QueryClient;
const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
let isPro = true;
beforeEach(() => {
  isPro = true;
  const entitlement = spyOn(Pro, "useProEntitlements").mockImplementation(() => ({ isPro }) as ReturnType<typeof Pro.useProEntitlements>); restores.push(() => entitlement.mockRestore());
  const scheduler = spyOn(scheduling, "useSkejScheduling").mockReturnValue({ readiness: { data: { accountDid: oauth.did, connected: true }, isPending: false, isError: false, refetch: async () => ({}) }, schedules: {}, pending: false, schedule: async () => ({}), cancel: async () => {}, reschedule: async () => {}, connectUrl: "https://skej.test/connect" } as unknown as ReturnType<typeof scheduling.useSkejScheduling>); restores.push(() => scheduler.mockRestore());
  const stored = spyOn(storedAuth, "getStoredOAuthDid").mockReturnValue(oauth.did); restores.push(() => stored.mockRestore());
  const linked = spyOn(brands, "useBrandAccounts").mockReturnValue([]); restores.push(() => linked.mockRestore());
  const profile = spyOn(profiles, "getBrandAccountPublicProfile").mockImplementation(async did => ({ did, handle: did === oauth.did ? "viewer.test" : "brand.test", displayName: did === oauth.did ? "Personal" : "Brand" })); restores.push(() => profile.mockRestore());
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const spy = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession: () => oauth } as ReturnType<typeof auth.useAuth>);
  restores.push(() => spy.mockRestore());
  const values = { DOMRect: window.DOMRect, Element: window.Element, HTMLElement: window.HTMLElement, Node: window.Node, MutationObserver: window.MutationObserver, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout };
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
  return await screen.findByRole("textbox", { name: "Post Text" });
}

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
  await screen.findByRole("status");
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

it("enforces grapheme limits and resets cancelled content when reopened", async () => {
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
  expect((await screen.findByRole("textbox", { name: "Post Text" }) as HTMLTextAreaElement).value).toBe("");
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
  expect(publish).toHaveBeenCalledTimes(1);
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
});

it("isolates personal drafts and pending guards when the owner changes", async () => {
  let captured: Parameters<typeof compose.createBlueskyPost>[0] | undefined;
  let finish!: (result: { uri: string; cid: string }) => void;
  const publish = spyOn(compose, "createBlueskyPost").mockImplementation(args => { captured = args; return new Promise(resolve => { finish = resolve; }); }); restores.push(() => publish.mockRestore());
  const view = render(<QueryClientProvider client={cache}><SocialComposeButton /></QueryClientProvider>);
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  fireEvent.change(await screen.findByRole("textbox", { name: "Post Text" }), { target: { value: "Private Old Draft" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
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
