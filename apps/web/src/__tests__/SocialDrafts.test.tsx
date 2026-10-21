import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { AppBskyDraftDefs } from "@atproto/api";
import * as auth from "@/hooks/useAuth";
import * as client from "@/lib/blueskyDraftClient";
import * as composer from "@/components/Social/SocialComposeButton";
import { SidebarProvider } from "@/components/ui/sidebar";
import { SocialDrafts } from "@/components/Social/SocialDrafts";
import DraftsPage from "@/app/social/drafts/page";
import { shouldPersistSocialQuery } from "@/lib/socialQueryPersist";
import * as attachments from "@/lib/socialDraftAttachmentClient";
import * as deletionStorage from "@/lib/socialDraftDeletionStorage";

const a = { did: "did:plc:alice" } as unknown as OAuthSession;
const b = { did: "did:plc:bob" } as unknown as OAuthSession;
let oauth = a;
let cache: QueryClient;
let opened: React.ComponentProps<typeof composer.SocialComposeButton> | undefined;
const restores: (() => void)[] = [];
function draft(id = "one", text = "Private draft", updatedAt = "2026-10-20T15:00:00Z"): AppBskyDraftDefs.DraftView {
  return { id, createdAt: updatedAt, updatedAt, draft: { posts: [{ text }] } };
}
beforeEach(() => {
  oauth = a;
  opened = undefined;
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const authSpy = spyOn(auth, "useAuth").mockImplementation(() => ({ session: { did: oauth.did }, getOAuthSession: () => oauth, signIn: async () => {} }) as unknown as ReturnType<typeof auth.useAuth>);
  const composeSpy = spyOn(composer, "SocialComposeButton").mockImplementation((props = {}) => {
    opened = props;
    return <div role="dialog" aria-label="Shared Composer"><button onClick={() => (props.onClose as () => void)()}>Close Editor</button></div>;
  });
  const listSpy = spyOn(client, "listSocialDrafts").mockResolvedValue({ drafts: [draft()] });
  const deleteSpy = spyOn(client, "deleteSocialDraft").mockResolvedValue(undefined);
  restores.push(() => authSpy.mockRestore(), () => composeSpy.mockRestore(), () => listSpy.mockRestore(), () => deleteSpy.mockRestore());
  let pending: deletionStorage.PendingDraftDeletion[] = [];
  const pendingSpy = spyOn(deletionStorage, "pendingDraftDeletions").mockImplementation(async ownerDid => pending.filter(item => item.ownerDid === ownerDid));
  const saveSpy = spyOn(deletionStorage, "saveDraftDeletion").mockImplementation(async (ownerDid, draft, completed) => { pending = pending.filter(item => item.ownerDid !== ownerDid || item.draft.id !== draft.id); if (!completed) pending.push({ ownerDid, draft }); });
  const manifestSpy = spyOn(attachments, "getDraftAttachmentManifest").mockImplementation(async (_actor, draftId) => ({ draftId, revision: 0, deleted: false, attachments: [] }));
  const cleanupSpy = spyOn(attachments, "deleteDraftAttachmentManifest").mockImplementation(async (_actor, draftId) => ({ draftId, revision: 2, deleted: true, attachments: [] }));
  restores.push(() => pendingSpy.mockRestore(), () => saveSpy.mockRestore(), () => manifestSpy.mockRestore(), () => cleanupSpy.mockRestore());
  for (const [name, value] of Object.entries({ matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }), getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const target = name === "matchMedia" ? window : globalThis;
    const previous = Object.getOwnPropertyDescriptor(target, name);
    Object.defineProperty(target, name, { configurable: true, value });
    restores.push(() => { if (previous) Object.defineProperty(target, name, previous); else Reflect.deleteProperty(target, name); });
  }
});
afterEach(async () => {
  await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); });
  cache.clear();
  restores.splice(0).reverse().forEach(restore => restore());
});
function view() { return <QueryClientProvider client={cache}><SidebarProvider><SocialDrafts /></SidebarProvider></QueryClientProvider>; }

it("renders drafts and hands the original object including unknown fields to the shared composer", async () => {
  const original = { ...draft(), futureField: { privateValue: true }, draft: { posts: [{ text: "Private draft", embedImages: [{ localRef: { path: "private/path" } }] }, { text: "Thread continuation" }] } };
  spyOn(client, "listSocialDrafts").mockResolvedValue({ drafts: [original] });
  render(view());
  const row = await screen.findByRole("button", { name: /Open Draft: Private draft/ });
  expect(screen.getByText(/2 Posts/)).toBeTruthy();
  expect(screen.getByText(/Media is available on the original device/)).toBeTruthy();
  expect(screen.queryByText("private/path")).toBeNull();
  expect(screen.queryByRole("button", { name: /Publish|Schedule/ })).toBeNull();
  fireEvent.click(row);
  expect(opened?.initialDraft).toBe(original);
  expect(opened).toMatchObject({ autoOpen: true, hideTrigger: true });
  fireEvent.click(screen.getByRole("button", { name: "Close Editor" }));
  fireEvent.click(screen.getByRole("button", { name: "New Post" }));
  expect(opened?.initialDraft).toBeUndefined();
  expect(screen.getAllByRole("dialog", { name: "Shared Composer" })).toHaveLength(1);
});

it("requires confirmation, supports Cancel, and preserves the row and retry after a failed deletion", async () => {
  const remove = spyOn(client, "deleteSocialDraft").mockRejectedValueOnce(new Error("network failure")).mockResolvedValue(undefined);
  const list = spyOn(client, "listSocialDrafts").mockResolvedValue({ drafts: [draft()] });
  render(view());
  fireEvent.click(await screen.findByRole("button", { name: "Delete Draft" }));
  expect(remove).not.toHaveBeenCalled();
  let dialog = await screen.findByRole("dialog", { name: "Delete Draft?" });
  expect(within(dialog).getByText("Delete this saved draft? This cannot be undone.")).toBeTruthy();
  fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
  expect(remove).not.toHaveBeenCalled();
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  fireEvent.click(screen.getByRole("button", { name: "Delete Draft" }));
  dialog = await screen.findByRole("dialog", { name: "Delete Draft?" });
  fireEvent.click(within(dialog).getByRole("button", { name: "Delete Draft" }));
  await screen.findByText("The draft could not be deleted. Please retry.");
  expect(document.body.textContent).toContain("Private draft");
  expect(screen.queryByText("network failure")).toBeNull();
  list.mockResolvedValue({ drafts: [] });
  fireEvent.click(within(dialog).getByRole("button", { name: "Retry Delete" }));
  await screen.findByText("No Drafts Yet");
  expect(remove).toHaveBeenCalledTimes(2);
  expect(remove.mock.calls[1][0]).toMatchObject({ viewerDid: a.did, id: "one" });
});

it("keeps a confirmed deletion hidden when the service returns its stale indexed row", async () => {
  render(view());
  fireEvent.click(await screen.findByRole("button", { name: "Delete Draft" }));
  const dialog = await screen.findByRole("dialog", { name: "Delete Draft?" });
  fireEvent.click(within(dialog).getByRole("button", { name: "Delete Draft" }));
  await screen.findByText("No Drafts Yet");
  fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(client.listSocialDrafts).toHaveBeenCalledTimes(3));
  expect(screen.queryByRole("button", { name: /Open Draft: Private draft/ })).toBeNull();
});

it("restores failed private-file deletion after remount even when the native draft is gone", async () => {
  spyOn(attachments, "getDraftAttachmentManifest").mockResolvedValue({ draftId: "one", revision: 1, deleted: false, attachments: [] });
  const removeFiles = spyOn(attachments, "deleteDraftAttachmentManifest").mockRejectedValueOnce(new Error("storage unavailable")).mockResolvedValue({ draftId: "one", revision: 2, deleted: true, attachments: [] });
  const first = render(view());
  fireEvent.click(await screen.findByRole("button", { name: "Delete Draft" }));
  fireEvent.click(within(await screen.findByRole("dialog", { name: "Delete Draft?" })).getByRole("button", { name: "Delete Draft" }));
  await screen.findByText("The draft could not be deleted. Please retry.");
  expect((document.querySelector('button[aria-label="Open Draft: Private draft"]') as HTMLButtonElement).disabled).toBe(true);
  expect(deletionStorage.saveDraftDeletion).toHaveBeenCalledWith(a.did, expect.objectContaining({ id: "one" }));
  first.unmount();
  cache.clear();
  spyOn(client, "listSocialDrafts").mockResolvedValue({ drafts: [] });
  render(view());
  fireEvent.click(await screen.findByRole("button", { name: "Retry Delete" }));
  fireEvent.click(within(await screen.findByRole("dialog", { name: "Delete Draft?" })).getByRole("button", { name: "Delete Draft" }));
  await screen.findByText("No Drafts Yet");
  expect(removeFiles).toHaveBeenCalledTimes(2);
  expect(deletionStorage.saveDraftDeletion).toHaveBeenLastCalledWith(a.did, expect.objectContaining({ id: "one" }), true);
});

it("disables dismissal and duplicate deletion while pending", async () => {
  let finish!: () => void;
  spyOn(client, "deleteSocialDraft").mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  render(view());
  fireEvent.click(await screen.findByRole("button", { name: "Delete Draft" }));
  const dialog = await screen.findByRole("dialog", { name: "Delete Draft?" });
  fireEvent.click(within(dialog).getByRole("button", { name: "Delete Draft" }));
  await waitFor(() => expect((within(dialog).getByRole("button", { name: "Cancel" }) as HTMLButtonElement).disabled).toBe(true));
  expect((within(dialog).getByRole("button", { name: "Deleting…" }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.keyDown(dialog, { key: "Escape" });
  expect(screen.getByRole("dialog", { name: "Delete Draft?" })).toBeTruthy();
  await act(async () => { finish(); });
});

it("deduplicates, orders by last update, stops repeated cursors, and refreshes visibly", async () => {
  const list = spyOn(client, "listSocialDrafts").mockImplementation(async ({ cursor }) => cursor ? { drafts: [draft("one", "Newest version", "2026-10-20T17:00:00Z"), draft("two", "Middle", "2026-10-20T16:00:00Z")], cursor: "next" } : { drafts: [draft()], cursor: "next" });
  render(view());
  fireEvent.click(await screen.findByRole("button", { name: "Load More" }));
  await screen.findByRole("button", { name: "Open Draft: Newest version" });
  expect(screen.getAllByRole("button", { name: /^Open Draft:/ }).map(row => row.textContent)).toEqual([expect.stringContaining("Newest version"), expect.stringContaining("Middle")]);
  expect(screen.queryByRole("button", { name: "Load More" })).toBeNull();
  expect(list.mock.calls[1][0].cursor).toBe("next");
  const count = list.mock.calls.length;
  fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(list.mock.calls.length).toBeGreaterThan(count));
});

it("clears editor on account changes and rejects late list results", async () => {
  let resolveAlice!: (value: { drafts: AppBskyDraftDefs.DraftView[] }) => void;
  let assertAlice: (() => void) | undefined;
  spyOn(client, "listSocialDrafts").mockImplementation(args => {
    if (args.viewerDid === a.did) { assertAlice = args.assertCurrentActor; return new Promise(resolve => { resolveAlice = resolve; }); }
    return Promise.resolve({ drafts: [draft("bob", "Bob draft")] });
  });
  const rendered = render(view());
  await waitFor(() => expect(assertAlice).toBeDefined());
  oauth = b;
  rendered.rerender(view());
  await screen.findByRole("button", { name: "Open Draft: Bob draft" });
  expect(() => assertAlice?.()).toThrow("account changed");
  await act(async () => { resolveAlice({ drafts: [draft()] }); });
  expect(screen.queryByRole("button", { name: "Open Draft: Private draft" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Open Draft: Bob draft" }));
  expect(screen.getByRole("dialog", { name: "Shared Composer" })).toBeTruthy();
  oauth = a;
  rendered.rerender(view());
  expect(screen.queryByRole("dialog", { name: "Shared Composer" })).toBeNull();
});

it("shows permission recovery without exposing transport payloads", async () => {
  spyOn(client, "listSocialDrafts").mockRejectedValue(new Error("missing required scope: sensitive payload"));
  render(view());
  await screen.findByRole("button", { name: "Log In Again" });
  expect(screen.queryByText(/sensitive payload/)).toBeNull();
});

it("keeps the drafts namespace outside persisted Social queries", () => {
  expect(shouldPersistSocialQuery({ queryKey: ["socialDrafts", a.did, 0], state: { data: { pages: [{ drafts: [draft()] }] } } })).toBe(false);
});

it("rejects a late delete after switching accounts without removing the new account's matching ID", async () => {
  let finish!: () => void;
  let assertOldActor: (() => void) | undefined;
  spyOn(client, "deleteSocialDraft").mockImplementation(args => {
    assertOldActor = args.assertCurrentActor;
    return new Promise(resolve => { finish = resolve; });
  });
  spyOn(client, "listSocialDrafts").mockImplementation(async args => ({ drafts: [draft("same", args.viewerDid === a.did ? "Alice draft" : "Bob draft")] }));
  const rendered = render(view());
  fireEvent.click(await screen.findByRole("button", { name: "Delete Draft" }));
  const dialog = await screen.findByRole("dialog", { name: "Delete Draft?" });
  fireEvent.click(within(dialog).getByRole("button", { name: "Delete Draft" }));
  await waitFor(() => expect(assertOldActor).toBeDefined());
  oauth = b;
  rendered.rerender(view());
  await screen.findByRole("button", { name: "Open Draft: Bob draft" });
  expect(screen.queryByRole("dialog", { name: "Delete Draft?" })).toBeNull();
  expect(() => assertOldActor?.()).toThrow("account changed");
  await act(async () => { finish(); });
  expect(screen.getByRole("button", { name: "Open Draft: Bob draft" })).toBeTruthy();
});

it("shows loading, a persistent generic error, then recovers through Retry to an empty state", async () => {
  let reject!: (error: Error) => void;
  const list = spyOn(client, "listSocialDrafts").mockImplementation(() => new Promise((_resolve, fail) => { reject = fail; }));
  render(view());
  expect(screen.getByRole("status").textContent).toBe("Loading drafts…");
  await act(async () => { reject(new Error("private response body")); });
  await screen.findByText("Drafts could not be loaded. Please retry.");
  expect(list).toHaveBeenCalledTimes(1);
  expect(screen.queryByText("private response body")).toBeNull();
  list.mockResolvedValue({ drafts: [] });
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await screen.findByText("No Drafts Yet");
  expect(screen.getByText("Your posts are autosaved as drafts while you write.")).toBeTruthy();
  fireEvent.click(screen.getAllByRole("button", { name: "New Post" })[1]);
  expect(opened).toMatchObject({ autoOpen: true, hideTrigger: true });
});


it("hands the Drafts route through to the private list and shared composer", async () => {
  render(<QueryClientProvider client={cache}><SidebarProvider><DraftsPage /></SidebarProvider></QueryClientProvider>);
  expect(screen.getByRole("heading", { name: "Drafts" })).toBeTruthy();
  fireEvent.click(await screen.findByRole("button", { name: "Open Draft: Private draft" }));
  expect(screen.getByRole("dialog", { name: "Shared Composer" })).toBeTruthy();
  expect(opened).toMatchObject({ initialDraft: { id: "one" }, autoOpen: true, hideTrigger: true });
});
