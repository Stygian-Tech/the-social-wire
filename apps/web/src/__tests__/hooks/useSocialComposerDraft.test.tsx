import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { useRef, useState } from "react";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { indexedDB } from "fake-indexeddb";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { AppBskyDraftDefs } from "@atproto/api";
import { useSocialComposerDraft } from "@/hooks/useSocialComposerDraft";
import type { ThreadPublication, ThreadSegment } from "@/lib/blueskyThreadClient";
import * as Transport from "@/lib/blueskyDraftClient";
import * as Storage from "@/lib/composerDraftStorage";

let count = 0;
let did: string;
let session: OAuthSession;
let remote: AppBskyDraftDefs.DraftView[];
const restores: (() => void)[] = [];
const originalIDB = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
const originalLocalStorage = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
const originalLocks = Object.getOwnPropertyDescriptor(navigator, "locks");
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (error: Error) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function view(id: string, draft: AppBskyDraftDefs.Draft): AppBskyDraftDefs.DraftView { return { id, draft: structuredClone(draft), createdAt: "2026-10-20T00:00:00Z", updatedAt: "2026-10-20T00:00:00Z" }; }
function harness(initialDraft?: AppBskyDraftDefs.DraftView) {
  return renderHook(({ enabled, actor = session }) => {
    const [segments, setSegments] = useState<ThreadSegment[]>([{ id: "initial", text: "" }]);
    const publicationRef = useRef<ThreadPublication | undefined>(undefined);
    const draft = useSocialComposerDraft({ ownerDid: did, session: actor, enabled, initialDraft, segments, publicationRef, restore: setSegments });
    return { ...draft, segments, setSegments, publicationRef };
  }, { initialProps: { enabled: true, actor: session } });
}
beforeEach(() => {
  did = `did:plc:autosave-${++count}`; session = { did } as OAuthSession; remote = [];
  Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: indexedDB });
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: window.localStorage });
  const held = new Set<string>();
  Object.defineProperty(navigator, "locks", { configurable: true, value: {
    async request<T>(name: string, options: LockOptions, callback: (lock: Lock | null) => Promise<T>): Promise<T> {
      if (options.signal && options.ifAvailable) throw new TypeError("The 'signal' and 'ifAvailable' options cannot be used together.");
      options.signal?.throwIfAborted();
      if (held.has(name)) return callback(null);
      held.add(name);
      try { return await callback({ name, mode: "exclusive" }); } finally { held.delete(name); }
    },
  } });
  for (const mock of [
    spyOn(Transport, "listSocialDrafts").mockImplementation(async () => ({ drafts: structuredClone(remote) })),
    spyOn(Transport, "createSocialDraft").mockImplementation(async ({ draft }) => { const id = `cloud-${remote.length + 1}`; remote.push(view(id, draft)); return { id }; }),
    spyOn(Transport, "updateSocialDraft").mockImplementation(async ({ id, draft }) => { remote = remote.map(item => item.id === id ? view(id, draft) : item); }),
    spyOn(Transport, "deleteSocialDraft").mockImplementation(async ({ id }) => { remote = remote.filter(item => item.id !== id); }),
  ]) restores.push(() => mock.mockRestore());
});
afterEach(async () => {
  cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); restores.splice(0).reverse().forEach(restore => restore());
  if (originalIDB) Object.defineProperty(globalThis, "indexedDB", originalIDB); else Reflect.deleteProperty(globalThis, "indexedDB");
  if (originalLocalStorage) Object.defineProperty(globalThis, "localStorage", originalLocalStorage); else Reflect.deleteProperty(globalThis, "localStorage");
  if (originalLocks) Object.defineProperty(navigator, "locks", originalLocks); else Reflect.deleteProperty(navigator, "locks");
});
it("saves locally before network, skips empty creates, and starts a new composition after close", async () => {
  const hook = harness();
  await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  await act(async () => hook.result.current.flush());
  expect(Transport.createSocialDraft).not.toHaveBeenCalled();
  act(() => hook.result.current.setSegments([{ id: "one", text: "**Private markdown**" }]));
  const create = spyOn(Transport, "createSocialDraft").mockImplementation(async ({ draft }) => {
    const local = await Storage.loadComposerDraft(did, "new-post");
    expect(local?.segments[0].text).toBe("**Private markdown**");
    expect(local?.cloud?.createIntent?.draft).toEqual(draft);
    remote.push(view("first", draft)); return { id: "first" };
  }); restores.push(() => create.mockRestore());
  await act(async () => hook.result.current.flush());
  expect(hook.result.current.cloudId).toBe("first");
  await act(async () => hook.result.current.close());
  expect(await Storage.loadComposerDraft(did, "new-post")).toBeUndefined();
  expect(Transport.deleteSocialDraft).not.toHaveBeenCalled();
  hook.rerender({ enabled: false, actor: session }); hook.rerender({ enabled: true, actor: session });
  await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.segments[0].text).toBe("");
  expect(hook.result.current.cloudId).toBeUndefined();
});
it("coalesces edits while create is pending and updates only after its ID is durable", async () => {
  const gate = deferred<{ id: string }>();
  const create = spyOn(Transport, "createSocialDraft").mockReturnValue(gate.promise); restores.push(() => create.mockRestore());
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "First" }]));
  let saving!: Promise<void>;
  act(() => { saving = hook.result.current.flush(); });
  await waitFor(() => expect(create).toHaveBeenCalledTimes(1));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Latest" }]));
  expect(Transport.updateSocialDraft).not.toHaveBeenCalled();
  await act(async () => { remote = [view("created", { posts: [{ text: "First" }], deviceId: window.localStorage.getItem("the-social-wire.social-draft-device.v1")! })]; gate.resolve({ id: "created" }); await saving; });
  expect(create).toHaveBeenCalledTimes(1);
  expect(Transport.updateSocialDraft).toHaveBeenCalledTimes(1);
  expect((await Storage.loadComposerDraft(did, "new-post"))?.cloud).toMatchObject({ id: "created", acknowledged: { posts: [{ text: "Latest" }] } });
});
it("never blindly retries ambiguous creates, including after reload, and reconciles exact payloads", async () => {
  let payload: AppBskyDraftDefs.Draft | undefined;
  const create = spyOn(Transport, "createSocialDraft").mockImplementation(async args => { payload = args.draft; throw new Error("Timeout"); }); restores.push(() => create.mockRestore());
  let hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Uncertain" }]));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Timeout"); });
  hook.unmount(); hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  await act(async () => { await expect(hook.result.current.retry()).rejects.toThrow("Without Creating Another"); });
  expect(create).toHaveBeenCalledTimes(1);
  remote = [view("reconciled", payload!)];
  await act(async () => hook.result.current.retry());
  expect(hook.result.current.cloudId).toBe("reconciled");
  expect(create).toHaveBeenCalledTimes(1);
});
it("checkpoint only persists local immutable attempted publication journals", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "In progress" }]));
  const publication: ThreadPublication = { did, segments: [{ draft: { id: "s", text: "Original immutable text" }, rkey: "key", attempted: true }] };
  hook.result.current.publicationRef.current = publication;
  await act(async () => { await hook.result.current.checkpoint(); await hook.result.current.flush(); });
  expect(Transport.createSocialDraft).not.toHaveBeenCalled();
  const saved = await Storage.loadComposerDraft(did, "new-post");
  expect(saved?.publication).toEqual(publication);
  await act(async () => hook.result.current.close());
  expect((await Storage.loadComposerDraft(did, "new-post"))?.publication).toEqual(publication);
});
it("persists completion before failed cloud cleanup and never restores a publishable copy", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Published" }]));
  await act(async () => hook.result.current.flush());
  const remove = spyOn(Transport, "deleteSocialDraft").mockImplementation(async () => {
    expect((await Storage.loadComposerDraft(did, "new-post"))?.cloud?.completed).toBe(true);
    throw new Error("Offline");
  }); restores.push(() => remove.mockRestore());
  await act(async () => { await expect(hook.result.current.clear()).rejects.toThrow("Offline"); });
  hook.unmount(); const reopened = harness(); await waitFor(() => expect(reopened.result.current.loaded).toBe(true));
  expect(reopened.result.current.segments[0].text).toBe("");
  await act(async () => { await expect(reopened.result.current.flush()).rejects.toThrow("Already Published"); });
  remove.mockImplementation(async () => {});
  await act(async () => reopened.result.current.retry());
  expect(await Storage.loadComposerDraft(did, "new-post")).toBeUndefined();
});
it("stops on changed remote payloads and retains the local copy", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }], langs: ["de"] }); remote = [initial];
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Local edit" }]));
  remote = [view("existing", { ...initial.draft, posts: [{ text: "Other device" }] })];
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Changed On Another Device"); });
  expect(Transport.updateSocialDraft).not.toHaveBeenCalled();
  expect((await Storage.loadComposerDraft(did, "social-draft:existing"))?.segments[0].text).toBe("Local edit");
});
it("ignores stale list payloads after acknowledging an update", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "First edit" }]));
  await act(async () => hook.result.current.flush());
  remote = [initial];
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Latest edit" }]));
  await act(async () => hook.result.current.flush());
  expect(hook.result.current.syncError).toBeUndefined();
  expect(remote[0].draft.posts[0].text).toBe("Latest edit");
});
it("refuses another session DID and blocks cloud requests if the local write fails", async () => {
  const wrong = harness(); await waitFor(() => expect(wrong.result.current.loaded).toBe(true));
  wrong.rerender({ enabled: true, actor: { did: "did:plc:other" } as unknown as OAuthSession });
  await waitFor(() => expect(wrong.result.current.storageError).toContain("Account Changed"));
  expect(Transport.listSocialDrafts).not.toHaveBeenCalled(); wrong.unmount();
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Private local" }]));
  const save = spyOn(Storage, "saveComposerDraft").mockRejectedValue(new Error("Quota")); restores.push(() => save.mockRestore());
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Quota"); });
  expect(Transport.createSocialDraft).not.toHaveBeenCalled();
  expect(hook.result.current.storageError).toContain("Keep This Window Open");
});
it("mirrors local files under the assigned cloud ID immediately and preserves them after close", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  const photo = { id: "photo", name: "private.jpg", original: new Blob(["private bytes"]), blob: new Blob(["private bytes"]), width: 10, height: 20, alt: "Description", status: "ready" as const };
  act(() => hook.result.current.setSegments([{ id: "photo-segment", text: "", media: { kind: "photos", photos: [photo] } }]));
  await act(async () => hook.result.current.flush());
  const cloudId = hook.result.current.cloudId!;
  let backup = await Storage.loadComposerDraft(did, `social-draft:${cloudId}`);
  expect(backup?.segments[0].media?.kind).toBe("photos");
  if (backup?.segments[0].media?.kind !== "photos") throw new Error("Missing Photo");
  expect(await backup.segments[0].media.photos[0].original.text()).toBe("private bytes");
  await act(async () => hook.result.current.close());
  expect(await Storage.loadComposerDraft(did, "new-post")).toBeUndefined();
  hook.unmount(); const editing = harness(remote[0]); await waitFor(() => expect(editing.result.current.loaded).toBe(true));
  expect(editing.result.current.hasUnavailableMedia).toBe(false);
  expect(editing.result.current.segments[0].media?.kind).toBe("photos");
  await act(async () => editing.result.current.clear());
  backup = await Storage.loadComposerDraft(did, `social-draft:${cloudId}`);
  expect(backup?.cloud).toMatchObject({ completed: true, cleaned: true }); expect(editing.result.current.completed).toBe(true);
});
it("keeps completion locked through scheduling-style cleanup failure and success without a publication", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Scheduled successfully" }]));
  await act(async () => hook.result.current.flush());
  const cloudId = hook.result.current.cloudId!;
  const remove = spyOn(Transport, "deleteSocialDraft").mockRejectedValue(new Error("Delete failed")); restores.push(() => remove.mockRestore());
  await act(async () => { await expect(hook.result.current.clear()).rejects.toThrow("Delete failed"); });
  expect(hook.result.current.publicationRef.current).toBeUndefined();
  expect(hook.result.current.completed).toBe(true); expect(hook.result.current.cleanupPending).toBe(true);
  expect((await Storage.loadComposerDraft(did, "new-post"))?.cloud?.completed).toBe(true);
  expect((await Storage.loadComposerDraft(did, `social-draft:${cloudId}`))?.cloud?.completed).toBe(true);
  remove.mockImplementation(async () => {});
  await act(async () => hook.result.current.retry());
  expect(hook.result.current.completed).toBe(true); expect(hook.result.current.cleanupPending).toBe(false);
  expect(await Storage.loadComposerDraft(did, "new-post")).toBeUndefined();
  expect((await Storage.loadComposerDraft(did, `social-draft:${cloudId}`))?.cloud).toMatchObject({ completed: true, cleaned: true });
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Already Published"); });
});
it("refuses to acknowledge updates for a cloud ID missing from the list", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "New local edit" }]));
  remote = [];
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Not Available Yet Or Was Deleted"); });
  expect(Transport.updateSocialDraft).not.toHaveBeenCalled();
  expect(hook.result.current.status).toBe("Draft Saved Locally");
  expect((await Storage.loadComposerDraft(did, "social-draft:existing"))?.segments[0].text).toBe("New local edit");
  remote = [initial]; await act(async () => hook.result.current.retry());
  expect(Transport.updateSocialDraft).toHaveBeenCalledTimes(1);
});
it("keeps compact completed tombstones when stale lists return successfully deleted drafts", async () => {
  let hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Already published" }]));
  await act(async () => hook.result.current.flush());
  const stale = structuredClone(remote[0]);
  await act(async () => hook.result.current.clear());
  const marker = await Storage.loadComposerDraft(did, `social-draft:${stale.id}`);
  expect(marker?.cloud).toMatchObject({ id: stale.id, completed: true, cleaned: true });
  expect(marker?.segments[0].text).toBe(""); expect(marker?.publication).toBeUndefined(); expect(marker?.cloud?.nativeDraft).toBeUndefined();
  hook.unmount(); remote = [stale]; hook = harness(stale);
  await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.completed).toBe(true); expect(hook.result.current.cleanupPending).toBe(false);
  expect(hook.result.current.segments[0].text).toBe("");
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Already Published"); });
  expect(Transport.createSocialDraft).toHaveBeenCalledTimes(1);
  await act(async () => hook.result.current.retry());
  expect(Transport.deleteSocialDraft).toHaveBeenCalledTimes(1);
});
it("marks and retires matching new-post recovery when publishing through its cloud editor", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Shared recovery" }]));
  await act(async () => hook.result.current.flush());
  const initial = structuredClone(remote[0]); hook.unmount();
  const editing = harness(initial); await waitFor(() => expect(editing.result.current.loaded).toBe(true));
  const remove = spyOn(Transport, "deleteSocialDraft").mockImplementation(async () => {
    expect((await Storage.loadComposerDraft(did, "new-post"))?.cloud?.completed).toBe(true);
    expect((await Storage.loadComposerDraft(did, `social-draft:${initial.id}`))?.cloud?.completed).toBe(true);
  }); restores.push(() => remove.mockRestore());
  await act(async () => editing.result.current.clear());
  expect(await Storage.loadComposerDraft(did, "new-post")).toBeUndefined();
  expect((await Storage.loadComposerDraft(did, `social-draft:${initial.id}`))?.cloud).toMatchObject({ completed: true, cleaned: true });
});
it("rejects late actor responses without assigning their cloud IDs to the new account", async () => {
  const gate = deferred<{ id: string }>();
  const create = spyOn(Transport, "createSocialDraft").mockReturnValue(gate.promise); restores.push(() => create.mockRestore());
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  const originalDid = did;
  act(() => hook.result.current.setSegments([{ id: "s", text: "Original account private text" }]));
  let error: unknown; let saving!: Promise<void>;
  act(() => { saving = hook.result.current.flush().catch(failure => { error = failure; }); });
  await waitFor(() => expect(create).toHaveBeenCalledTimes(1));
  did = `${did}-other`; session = { did } as OAuthSession;
  hook.rerender({ enabled: true, actor: session });
  await waitFor(() => expect(hook.result.current.segments[0].text).toBe(""));
  await act(async () => { gate.resolve({ id: "stale-account-cloud-id" }); await saving; });
  expect(error).toBeInstanceOf(Error); expect(hook.result.current.cloudId).toBeUndefined();
  expect((await Storage.loadComposerDraft(originalDid, "new-post"))?.cloud?.createIntent).toBeDefined();
  expect((await Storage.loadComposerDraft(did, "new-post"))?.segments[0].text).toBe("");
});
it("resumes newer native payloads when local recovery has no unsynced changes", async () => {
  let hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Old acknowledged" }]));
  await act(async () => hook.result.current.flush());
  const initial = structuredClone(remote[0]); hook.unmount();
  initial.draft.posts[0].text = "New remote text"; initial.draft.langs = ["fr"];
  remote = [initial]; hook = harness(initial);
  await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.segments[0].text).toBe("New remote text");
  expect(hook.result.current.syncError).toBeUndefined();
  expect((await Storage.loadComposerDraft(did, `social-draft:${initial.id}`))?.cloud?.nativeDraft?.langs).toEqual(["fr"]);
});
it("preserves unsynced recovery and stops on a conflicting remote version during resume", async () => {
  let hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Acknowledged" }]));
  await act(async () => hook.result.current.flush());
  const initial = structuredClone(remote[0]);
  act(() => hook.result.current.setSegments([{ id: "s", text: "Unsynced local" }]));
  await act(async () => hook.result.current.checkpoint()); hook.unmount();
  initial.draft.posts[0].text = "Conflicting remote"; remote = [initial]; hook = harness(initial);
  await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.segments[0].text).toBe("Unsynced local");
  expect(hook.result.current.syncError).toContain("Changed On Another Device");
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Changed On Another Device"); });
  expect(Transport.updateSocialDraft).not.toHaveBeenCalled();
});
it("admits only one same-account editor while a non-idempotent create is delayed", async () => {
  const gate = deferred<{ id: string }>();
  const create = spyOn(Transport, "createSocialDraft").mockReturnValue(gate.promise); restores.push(() => create.mockRestore());
  const first = harness(); await waitFor(() => expect(first.result.current.loaded).toBe(true));
  act(() => first.result.current.setSegments([{ id: "s", text: "Only admitted writer" }]));
  let saving!: Promise<void>; act(() => { saving = first.result.current.flush(); });
  await waitFor(() => expect(create).toHaveBeenCalledTimes(1));
  const second = harness();
  await waitFor(() => expect(second.result.current.storageError).toContain("Already Open In Another Window"));
  expect(second.result.current.loaded).toBe(false);
  await act(async () => { await expect(second.result.current.flush()).rejects.toThrow("Wait For Draft Recovery"); await second.result.current.close(); });
  expect((await Storage.loadComposerDraft(did, "new-post"))?.segments[0].text).toBe("Only admitted writer");
  await act(async () => { gate.resolve({ id: "one-cloud" }); await saving; });
  expect(create).toHaveBeenCalledTimes(1);
});
it("protects an existing cloud draft from concurrent editors and fails closed without Web Locks", async () => {
  const initial = view("existing", { posts: [{ text: "Remote original" }] }); remote = [initial];
  const first = harness(initial); await waitFor(() => expect(first.result.current.loaded).toBe(true));
  const second = harness(initial); await waitFor(() => expect(second.result.current.storageError).toContain("Already Open"));
  expect(Transport.updateSocialDraft).not.toHaveBeenCalled(); first.unmount(); second.unmount();
  Object.defineProperty(navigator, "locks", { configurable: true, value: undefined });
  const unavailable = harness(initial);
  await waitFor(() => expect(unavailable.result.current.storageError).toContain("Exclusive Draft Editing Is Unavailable"));
  expect(unavailable.result.current.loaded).toBe(false);
  await act(async () => unavailable.result.current.close());
  expect((await Storage.loadComposerDraft(did, "social-draft:existing"))?.segments[0].text).toBe("Remote original");
});
it("retains pending updates when a successful response is a silent no-op and only acknowledges readback", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const update = spyOn(Transport, "updateSocialDraft").mockImplementation(async () => { remote = []; }); restores.push(() => update.mockRestore());
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Pending edit" }]));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Update Could Not Be Confirmed"); });
  const pending = (await Storage.loadComposerDraft(did, "social-draft:existing"))?.cloud;
  expect(pending?.acknowledged?.posts[0].text).toBe("Original");
  expect(pending?.pendingUpdate?.draft.posts[0].text).toBe("Pending edit");
  expect(hook.result.current.status).toBe("Draft Saved Locally");
  remote = [view("existing", pending!.pendingUpdate!.draft)];
  await act(async () => hook.result.current.retry());
  expect(update).toHaveBeenCalledTimes(1);
  expect(hook.result.current.status).toBe("Draft Saved");
  expect((await Storage.loadComposerDraft(did, "social-draft:existing"))?.cloud?.pendingUpdate).toBeUndefined();
});
it("forks conflicts into a distinct cloud draft and cleans the original recovery after confirmation", async () => {
  const initial = view("original", { posts: [{ text: "Original" }] }); remote = [initial];
  let hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Private local conflict" }]));
  remote = [view("original", { posts: [{ text: "Changed remotely" }] })];
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Changed On Another Device"); });
  expect(hook.result.current.hasConflict).toBe(true);
  await act(async () => hook.result.current.forkLocal());
  const forkId = hook.result.current.cloudId!;
  expect(forkId).not.toBe("original"); expect(remote.find(item => item.id === forkId)?.draft.posts[0].text).toBe("Private local conflict");
  const fork = await Storage.loadComposerDraft(did, `social-draft:${forkId}`);
  expect(fork?.segments[0].text).toBe("Private local conflict");
  expect(fork?.cloud?.conflictCopyContext).toContain("social-conflict:");
  expect((await Storage.loadComposerDraft(did, fork!.cloud!.conflictCopyContext!))?.segments[0].text).toBe("Private local conflict");
  expect((await Storage.loadComposerDraft(did, "social-draft:original"))?.segments[0].text).toBe("Changed remotely");
  expect(await Storage.loadComposerDraft(did, "new-post")).toBeUndefined();
  hook.unmount(); hook = harness(remote.find(item => item.id === "original"));
  await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.hasConflict).toBe(false); expect(hook.result.current.segments[0].text).toBe("Changed remotely");
});
it("opening remote first saves the conflict as a discoverable cloud fork and adopts actual publish settings", async () => {
  const initial = view("original", { posts: [{ text: "Original" }] }); remote = [initial];
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.unsupportedPublishSettings).toBe(false);
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Local preserved in Drafts" }]));
  remote = [view("original", { posts: [{ text: "Remote", labels: { $type: "com.atproto.label.defs#selfLabels", values: [] } }], langs: ["ja"] })];
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Changed On Another Device"); });
  await act(async () => hook.result.current.openRemote());
  expect(hook.result.current.cloudId).toBe("original"); expect(hook.result.current.segments[0].text).toBe("Remote");
  expect(hook.result.current.hasConflict).toBe(false); expect(hook.result.current.unsupportedPublishSettings).toBe(true);
  expect(remote.find(item => item.id !== "original")?.draft.posts[0].text).toBe("Local preserved in Drafts");
  expect((await Storage.loadComposerDraft(did, "social-draft:original"))?.segments[0].text).toBe("Remote");
});
it("does not reset conflict intent or create a fork if preserving the local copy fails", async () => {
  const initial = view("original", { posts: [{ text: "Original" }] }); remote = [initial];
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Local copy" }]));
  remote = [view("original", { posts: [{ text: "Remote conflict" }] })];
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Changed On Another Device"); });
  const originalSave = Storage.saveComposerDraft;
  const save = spyOn(Storage, "saveComposerDraft").mockImplementation((owner, context, draft) => context.startsWith("social-conflict:") ? Promise.reject(new Error("Quota")) : originalSave(owner, context, draft)); restores.push(() => save.mockRestore());
  await act(async () => { await expect(hook.result.current.forkLocal()).rejects.toThrow("Quota"); });
  expect(hook.result.current.cloudId).toBe("original"); expect(hook.result.current.hasConflict).toBe(true);
  expect(hook.result.current.segments[0].text).toBe("Local copy"); expect(Transport.createSocialDraft).not.toHaveBeenCalled();
});
it("reconciles a pending acknowledged update after reload without treating its readback as a conflict", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const update = spyOn(Transport, "updateSocialDraft").mockImplementation(async () => {}); restores.push(() => update.mockRestore());
  let hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Eventually visible" }]));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Update Could Not Be Confirmed"); });
  const pending = (await Storage.loadComposerDraft(did, "social-draft:existing"))?.cloud?.pendingUpdate;
  remote = [view("existing", pending!.draft)]; hook.unmount(); hook = harness(remote[0]);
  await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.hasConflict).toBe(false);
  await act(async () => hook.result.current.retry());
  expect(hook.result.current.status).toBe("Draft Saved"); expect(update).toHaveBeenCalledTimes(1);
});
