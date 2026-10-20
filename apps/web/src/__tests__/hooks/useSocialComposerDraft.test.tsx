import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { useRef, useState } from "react";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { indexedDB } from "fake-indexeddb";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { AppBskyDraftDefs } from "@atproto/api";
import { useSocialComposerDraft } from "@/hooks/useSocialComposerDraft";
import type { ThreadPublication, ThreadSegment } from "@/lib/blueskyThreadClient";
import * as Transport from "@/lib/blueskyDraftClient";
import * as Attachments from "@/lib/socialDraftAttachmentClient";
import * as Klipy from "@/lib/klipyClient";
import * as Gateway from "@/lib/socialWireGatewayClient";
import * as Storage from "@/lib/composerDraftStorage";

const realGetManifest = Attachments.getDraftAttachmentManifest;
let count = 0;
let did: string;
let session: OAuthSession;
let remote: AppBskyDraftDefs.DraftView[];
let manifests: Map<string, Attachments.DraftAttachmentManifest>;
let files: Map<string, { asset: Attachments.DraftAttachment; blob: Blob }>;
const originalBitmap = Object.getOwnPropertyDescriptor(globalThis, "createImageBitmap");
const restores: (() => void)[] = [];
const originalIDB = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
const originalLocalStorage = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
const originalLocks = Object.getOwnPropertyDescriptor(navigator, "locks");
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (error: Error) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function view(id: string, draft: AppBskyDraftDefs.Draft): AppBskyDraftDefs.DraftView { return { id, draft: structuredClone(draft), createdAt: "2026-10-20T00:00:00Z", updatedAt: "2026-10-20T00:00:00Z" }; }
function harness(initialDraft?: AppBskyDraftDefs.DraftView, onChanged?: () => void) {
  return renderHook(({ enabled, actor = session }) => {
    const [segments, setSegments] = useState<ThreadSegment[]>([{ id: "initial", text: "" }]);
    const publicationRef = useRef<ThreadPublication | undefined>(undefined);
    const draft = useSocialComposerDraft({ ownerDid: did, session: actor, enabled, initialDraft, segments, publicationRef, restore: setSegments, onChanged });
    return { ...draft, segments, setSegments, publicationRef };
  }, { initialProps: { enabled: true, actor: session } });
}
beforeEach(() => {
  did = `did:plc:autosave-${++count}`; session = { did } as OAuthSession; remote = [];
  Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: indexedDB });
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: window.localStorage });
  manifests = new Map(); files = new Map();
  Object.defineProperty(globalThis, "createImageBitmap", { configurable: true, value: async () => ({ width: 10, height: 20, close() {} }) });
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
    spyOn(Klipy, "getGifFile").mockImplementation(async (actor, id, rendition) => { Attachments.assertDraftAttachmentActor(actor); return new Blob([`${id}:${rendition}`], { type: rendition === "gif" ? "image/gif" : rendition === "poster" ? "image/jpeg" : `video/${rendition}` }); }),
    spyOn(Attachments, "uploadDraftAttachment").mockImplementation(async (actor, asset, blob) => { Attachments.assertDraftAttachmentActor(actor); const ready = { ...asset, state: "ready" as const }; files.set(asset.assetId, { asset: ready, blob }); return ready; }),
    spyOn(Attachments, "downloadDraftAttachment").mockImplementation(async (actor, asset) => { Attachments.assertDraftAttachmentActor(actor); const file = files.get(asset.assetId); if (!file) throw new Error("Private Photo Missing. Retry Or Reattach."); return file.blob; }),
    spyOn(Attachments, "getDraftAttachmentManifest").mockImplementation(async (actor, draftId) => { Attachments.assertDraftAttachmentActor(actor); return structuredClone(manifests.get(draftId) ?? { draftId, revision: 0, deleted: false, attachments: [] }); }),
    spyOn(Attachments, "putDraftAttachmentManifest").mockImplementation(async (actor, draftId, expectedRevision, attachments) => {
      Attachments.assertDraftAttachmentActor(actor);
      if ((manifests.get(draftId)?.revision ?? 0) !== expectedRevision) throw Object.assign(new Error("CAS conflict"), { status: 409 });
      const manifest = { draftId, revision: expectedRevision + 1, deleted: false, attachments: attachments.map(ref => ({ ...ref, asset: files.get(ref.assetId)!.asset })) };
      manifests.set(draftId, manifest); return structuredClone(manifest);
    }),
    spyOn(Attachments, "deleteDraftAttachmentManifest").mockImplementation(async (actor, draftId, expectedRevision) => {
      Attachments.assertDraftAttachmentActor(actor);
      const manifest = { draftId, revision: expectedRevision + 1, deleted: true, attachments: [] };
      manifests.set(draftId, manifest); return manifest;
    }),
    spyOn(Transport, "listSocialDrafts").mockImplementation(async () => ({ drafts: structuredClone(remote) })),
    spyOn(Transport, "createSocialDraft").mockImplementation(async ({ draft }) => { const id = `cloud-${remote.length + 1}`; remote.push(view(id, draft)); return { id }; }),
    spyOn(Transport, "updateSocialDraft").mockImplementation(async ({ id, draft }) => { remote = remote.map(item => item.id === id ? view(id, draft) : item); }),
    spyOn(Transport, "deleteSocialDraft").mockImplementation(async ({ id }) => { remote = remote.filter(item => item.id !== id); }),
  ]) restores.push(() => mock.mockRestore());
});
afterEach(async () => {
  cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); restores.splice(0).reverse().forEach(restore => restore());
  if (originalBitmap) Object.defineProperty(globalThis, "createImageBitmap", originalBitmap); else Reflect.deleteProperty(globalThis, "createImageBitmap");
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
  const photo = { id: "photo", name: "private.jpg", original: new Blob(["private bytes"], { type: "image/jpeg" }), blob: new Blob(["private bytes"], { type: "image/jpeg" }), width: 10, height: 20, alt: "Description", status: "ready" as const };
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

it("preserves a local draft and exposes permission recovery from structured scope errors", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "private", text: "Retain across renewed authorization" }]));
  const create = spyOn(Transport, "createSocialDraft").mockRejectedValue(Object.assign(new Error("Not allowed"), { error: "insufficient_scope" })); restores.push(() => create.mockRestore());
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Not allowed"); });
  expect(hook.result.current.syncError).toBe("Please log in again to update your account permissions, then retry this action.");
  expect((await Storage.loadComposerDraft(did, "new-post"))?.segments[0].text).toBe("Retain across renewed authorization");
  expect(Transport.deleteSocialDraft).not.toHaveBeenCalled();
  expect((await Storage.loadComposerDraft(did, "new-post"))?.cloud?.createIntent).toBeUndefined();
  create.mockResolvedValue({ id: "authorized" });
  await act(async () => hook.result.current.retry());
  expect(hook.result.current.cloudId).toBe("authorized");
  expect(create).toHaveBeenCalledTimes(2);
});
it.each([
  { error: "insufficient_scope" },
  { status: 401 },
  { statusCode: 403 },
  { response: { status: 403 } },
])("clears a definitively rejected update so renewed authorization can retry: %j", async failure => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const update = spyOn(Transport, "updateSocialDraft").mockRejectedValue(Object.assign(new Error("Rejected update"), failure)); restores.push(() => update.mockRestore());
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Keep this local edit" }]));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Rejected update"); });
  const recovery = await Storage.loadComposerDraft(did, "social-draft:existing");
  expect(recovery?.cloud?.pendingUpdate).toBeUndefined();
  expect(recovery?.cloud?.acknowledged?.posts[0].text).toBe("Original");
  expect(recovery?.segments[0].text).toBe("Keep this local edit");
  update.mockImplementation(async ({ id, draft }) => { remote = [view(id, draft)]; });
  await act(async () => hook.result.current.retry());
  expect(update).toHaveBeenCalledTimes(2); expect(hook.result.current.status).toBe("Draft Saved");
});
it("reconciles unknown updates after reload and only resends on an explicit retry", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const update = spyOn(Transport, "updateSocialDraft").mockRejectedValue(new Error("Network failure")); restores.push(() => update.mockRestore());
  let hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Uncertain replacement" }]));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Network failure"); });
  const pending = (await Storage.loadComposerDraft(did, "social-draft:existing"))?.cloud?.pendingUpdate;
  expect(pending?.draft.posts[0].text).toBe("Uncertain replacement");
  hook.unmount(); hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  update.mockImplementation(async ({ id, draft }) => { expect(draft).toEqual(pending!.draft); remote = [view(id, draft)]; });
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Update Could Not Be Confirmed"); });
  expect(update).toHaveBeenCalledTimes(1);
  await act(async () => hook.result.current.retry());
  expect(update).toHaveBeenCalledTimes(2); expect(hook.result.current.status).toBe("Draft Saved");
  const recovery = await Storage.loadComposerDraft(did, "social-draft:existing");
  expect(recovery?.cloud?.pendingUpdate).toBeUndefined();
  expect(recovery?.cloud?.conflictCopyContext).toContain("social-conflict:");
  expect((await Storage.loadComposerDraft(did, recovery!.cloud!.conflictCopyContext!))?.segments[0].text).toBe("Uncertain replacement");
});
it("acknowledges an applied unknown update without resending it", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const update = spyOn(Transport, "updateSocialDraft").mockImplementation(async ({ id, draft }) => { remote = [view(id, draft)]; throw new Error("Response lost"); }); restores.push(() => update.mockRestore());
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Already applied" }]));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Response lost"); });
  await act(async () => hook.result.current.retry());
  expect(update).toHaveBeenCalledTimes(1); expect(hook.result.current.status).toBe("Draft Saved");
  expect((await Storage.loadComposerDraft(did, "social-draft:existing"))?.cloud?.pendingUpdate).toBeUndefined();
});
it("does not resend pending replacements when the remote draft is missing", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const update = spyOn(Transport, "updateSocialDraft").mockRejectedValue(new Error("Network failure")); restores.push(() => update.mockRestore());
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Keep local" }]));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Network failure"); });
  remote = [];
  await act(async () => { await expect(hook.result.current.retry()).rejects.toThrow("Update Could Not Be Confirmed"); });
  expect(update).toHaveBeenCalledTimes(1); expect(hook.result.current.status).toBe("Draft Saved Locally");
  expect((await Storage.loadComposerDraft(did, "social-draft:existing"))?.cloud?.pendingUpdate?.draft.posts[0].text).toBe("Keep local");
});
it("limits an explicit retry to one resend and retains pending state when replacement silently no-ops", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const update = spyOn(Transport, "updateSocialDraft").mockImplementation(async () => {}); restores.push(() => update.mockRestore());
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Never acknowledged" }]));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Update Could Not Be Confirmed"); });
  await act(async () => { await expect(hook.result.current.retry()).rejects.toThrow("Update Could Not Be Confirmed"); });
  expect(update).toHaveBeenCalledTimes(2); expect(hook.result.current.status).toBe("Draft Saved Locally");
  const recovery = await Storage.loadComposerDraft(did, "social-draft:existing");
  expect(recovery?.cloud?.acknowledged?.posts[0].text).toBe("Original"); expect(recovery?.cloud?.pendingUpdate?.draft.posts[0].text).toBe("Never acknowledged");
}, 10_000);
it("freshly checks the remote again after preserving the local copy before a resend", async () => {
  const initial = view("existing", { posts: [{ text: "Original" }] }); remote = [initial];
  const update = spyOn(Transport, "updateSocialDraft").mockRejectedValue(new Error("Network failure")); restores.push(() => update.mockRestore());
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(previous => [{ ...previous[0], text: "Private recovery" }]));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Network failure"); });
  const originalSave = Storage.saveComposerDraft;
  const save = spyOn(Storage, "saveComposerDraft").mockImplementation(async (owner, context, draft) => {
    await originalSave(owner, context, draft);
    if (context.startsWith("social-conflict:")) remote = [view("existing", { posts: [{ text: "Concurrent remote change" }] })];
  }); restores.push(() => save.mockRestore());
  await act(async () => { await expect(hook.result.current.retry()).rejects.toThrow("Changed On Another Device"); });
  expect(update).toHaveBeenCalledTimes(1); expect(hook.result.current.hasConflict).toBe(true);
  const recovery = await Storage.loadComposerDraft(did, "social-draft:existing");
  expect((await Storage.loadComposerDraft(did, recovery!.cloud!.conflictCopyContext!))?.segments[0].text).toBe("Private recovery");
});
it("waits for a created cloud ID to become visible before closing and notifying the draft list", async () => {
  let created: AppBskyDraftDefs.Draft | undefined;
  const create = spyOn(Transport, "createSocialDraft").mockImplementation(async ({ draft }) => { created = draft; return { id: "indexing" }; }); restores.push(() => create.mockRestore());
  let notifications = 0;
  const hook = harness(undefined, () => { notifications++; }); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Indexed shortly" }]));
  await act(async () => hook.result.current.flush());
  const priorNotifications = notifications;
  const timer = setTimeout(() => { remote = [view("indexing", created!)]; }, 100); restores.push(() => clearTimeout(timer));
  await act(async () => hook.result.current.close());
  expect(notifications).toBeGreaterThan(priorNotifications); expect(remote[0].id).toBe("indexing");
  expect(await Storage.loadComposerDraft(did, "new-post")).toBeUndefined();
  expect((await Storage.loadComposerDraft(did, "social-draft:indexing"))?.segments[0].text).toBe("Indexed shortly");
  expect(create).toHaveBeenCalledTimes(1);
});
it("retains local recovery and never recreates a known ID when close cannot confirm its visibility", async () => {
  const create = spyOn(Transport, "createSocialDraft").mockResolvedValue({ id: "not-indexed" }); restores.push(() => create.mockRestore());
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments([{ id: "s", text: "Keep until visible" }]));
  await act(async () => hook.result.current.flush());
  await act(async () => { await expect(hook.result.current.close()).rejects.toThrow("Saved Draft Is Not Visible Yet"); });
  expect(hook.result.current.syncError).toContain("Saved Draft Is Not Visible Yet");
  expect((await Storage.loadComposerDraft(did, "new-post"))?.cloud?.id).toBe("not-indexed");
  expect(create).toHaveBeenCalledTimes(1); expect(Transport.deleteSocialDraft).not.toHaveBeenCalled();
});

function implementation<T extends (...args: never[]) => unknown>(value: T): T { return (value as T & { getMockImplementation(): T }).getMockImplementation(); }
function privatePhotoSegments(): ThreadSegment[] {
  return [{ id: "photo-post", text: "Private photo", media: { kind: "photos", photos: [{ id: "photo", name: "p.jpg", original: new Blob(["original private bytes"], { type: "image/png" }), blob: new Blob(["prepared private bytes"], { type: "image/jpeg" }), width: 10, height: 20, alt: "Description", status: "ready" }] } }];
}
it("restores original and prepared photo bytes in a fresh browser without IndexedDB recovery", async () => {
  let hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments()));
  await act(async () => hook.result.current.flush());
  const id = hook.result.current.cloudId!;
  expect(manifests.get(id)!.attachments.map(ref => ref.role).sort()).toEqual(["original", "prepared"]);
  expect(remote[0].draft.posts[0].embedImages?.[0].localRef.path).toMatch(/^socialwire-private:\/\/v1\/photo\//);
  expect(hook.result.current.status).toBe("Draft Saved"); hook.unmount();
  await Storage.saveComposerDraft(did, "new-post"); await Storage.saveComposerDraft(did, `social-draft:${id}`);
  hook = harness(remote[0]); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  const media = hook.result.current.segments[0].media;
  if (media?.kind !== "photos") throw new Error("Missing Restored Photos");
  expect(await media.photos[0].original.text()).toBe("original private bytes");
  expect(await media.photos[0].blob!.text()).toBe("prepared private bytes");
  expect(media.photos[0].status).toBe("ready"); expect(media.photos[0].alt).toBe("Description");
  expect(hook.result.current.hasUnavailableMedia).toBe(false);
});
it("checkpoints stable asset IDs before upload and retains them through a failed upload retry", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments()));
  const originalUpload = implementation(Attachments.uploadDraftAttachment); const ids: string[] = [];
  const upload = spyOn(Attachments, "uploadDraftAttachment").mockImplementation(async (_actor, asset) => {
    const recovery = await Storage.loadComposerDraft(did, "new-post"); const media = recovery?.segments[0].media;
    if (media?.kind !== "photos") throw new Error("Missing Durable Recovery");
    expect([media.photos[0].privateAttachment?.original.assetId, media.photos[0].privateAttachment?.prepared.assetId]).toContain(asset.assetId);
    ids.push(asset.assetId); throw new Error("Upload Failed");
  }); restores.push(() => upload.mockRestore());
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Upload Failed"); });
  expect(Transport.createSocialDraft).not.toHaveBeenCalled(); expect(hook.result.current.status).toBe("Draft Saved Locally");
  upload.mockImplementation(originalUpload); await act(async () => hook.result.current.retry());
  const media = hook.result.current.segments[0].media;
  if (media?.kind !== "photos") throw new Error("Missing Photos");
  expect(media.photos[0].privateAttachment?.original.assetId).toBe(ids[0]); expect(hook.result.current.status).toBe("Draft Saved");
});
it("keeps the native ID and local bytes when manifest commit fails and reconciles a lost commit response", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments()));
  const put = implementation(Attachments.putDraftAttachmentManifest);
  const commit = spyOn(Attachments, "putDraftAttachmentManifest").mockImplementation(async (...args) => { await put(...args); throw new Error("Manifest Response Lost"); }); restores.push(() => commit.mockRestore());
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Manifest Response Lost"); });
  expect(hook.result.current.cloudId).toBeDefined(); expect(hook.result.current.status).toBe("Draft Saved Locally");
  expect((await Storage.loadComposerDraft(did, "new-post"))?.cloud?.pendingManifest).toBeDefined();
  await act(async () => hook.result.current.retry()); expect(commit).toHaveBeenCalledTimes(1);
  expect(Transport.createSocialDraft).toHaveBeenCalledTimes(1); expect(hook.result.current.status).toBe("Draft Saved");
});
it("does not report Saved when manifest CAS conflicts and forks with shared asset IDs", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments()));
  const commit = implementation(Attachments.putDraftAttachmentManifest);
  const fail = spyOn(Attachments, "putDraftAttachmentManifest").mockRejectedValue(Object.assign(new Error("CAS conflict"), { status: 409 })); restores.push(() => fail.mockRestore());
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("CAS conflict"); });
  expect(hook.result.current.hasConflict).toBe(true); expect(hook.result.current.status).toBe("Draft Saved Locally");
  const sourceId = hook.result.current.cloudId!; const assetIds = [...files.keys()].sort(); fail.mockImplementation(commit);
  await act(async () => hook.result.current.forkLocal()); expect(hook.result.current.cloudId).not.toBe(sourceId);
  expect(manifests.get(hook.result.current.cloudId!)?.attachments.map(ref => ref.assetId).sort()).toEqual(assetIds);
  expect([...files.keys()].sort()).toEqual(assetIds);
});
it("retains completed recovery on companion cleanup failure and retries cleanup without native deletion again", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments())); await act(async () => hook.result.current.flush()); const id = hook.result.current.cloudId!;
  const remove = implementation(Attachments.deleteDraftAttachmentManifest);
  const cleanup = spyOn(Attachments, "deleteDraftAttachmentManifest").mockRejectedValue(new Error("Companion Unavailable")); restores.push(() => cleanup.mockRestore());
  await act(async () => { await expect(hook.result.current.clear()).rejects.toThrow("Companion Unavailable"); });
  const recovery = await Storage.loadComposerDraft(did, `social-draft:${id}`);
  expect(recovery?.cloud?.completed).toBe(true); expect(recovery?.cloud?.nativeDeleted).toBe(true);
  expect(hook.result.current.completed).toBe(true); expect(hook.result.current.cleanupPending).toBe(true);
  cleanup.mockImplementation(remove); await act(async () => hook.result.current.retry());
  expect(Transport.deleteSocialDraft).toHaveBeenCalledTimes(1); expect(manifests.get(id)?.deleted).toBe(true); expect(hook.result.current.cleanupPending).toBe(false);
});
it("keeps missing private files unavailable, blocks publication, and restores them on explicit retry", async () => {
  let hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments())); await act(async () => hook.result.current.flush()); const id = hook.result.current.cloudId!; hook.unmount();
  await Storage.saveComposerDraft(did, "new-post"); await Storage.saveComposerDraft(did, `social-draft:${id}`);
  const download = implementation(Attachments.downloadDraftAttachment);
  const missing = spyOn(Attachments, "downloadDraftAttachment").mockRejectedValue(new Error("Private Photo Missing. Retry Or Reattach.")); restores.push(() => missing.mockRestore());
  hook = harness(remote[0]); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.hasUnavailableMedia).toBe(true); expect(hook.result.current.syncError).toContain("Retry Or Reattach");
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Photos Are Unavailable"); });
  missing.mockImplementation(download); await act(async () => hook.result.current.retry());
  expect(hook.result.current.hasUnavailableMedia).toBe(false); expect(hook.result.current.status).toBe("Draft Saved");
});
it("never claims that external GIF or imported video bytes are privately synced", async () => {
  const gif = view("gif", { posts: [{ text: "", embedExternals: [{ uri: "https://static.klipy.com/ii/a/b.gif?ww=10&hh=20&mp4=b" }] }] });
  remote = [gif]; let hook = harness(gif); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Reselect"); }); expect(hook.result.current.hasUnavailableMedia).toBe(true); hook.unmount();
  const video = view("video", { posts: [{ text: "video", embedVideos: [{ localRef: { path: "file:///private/movie.mp4" } }] }] });
  remote = [video]; hook = harness(video); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  await act(async () => hook.result.current.flush()); expect(hook.result.current.status).toBe("Attachment Files Unavailable");
  expect(hook.result.current.hasUnavailableMedia).toBe(true); expect(Attachments.downloadDraftAttachment).not.toHaveBeenCalled();
});
it("preserves unsynced text and photo edits while reopening local private recovery", async () => {
  let hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments())); await act(async () => hook.result.current.flush());
  const id = hook.result.current.cloudId!; hook.unmount();
  const recovery = (await Storage.loadComposerDraft(did, `social-draft:${id}`))!;
  const edited = { ...recovery, segments: recovery.segments.map(segment => ({ ...segment, text: "Unsynced local edit", media: segment.media?.kind === "photos" ? { ...segment.media, photos: segment.media.photos.map(photo => ({ ...photo, alt: "Unsynced description" })) } : segment.media })) };
  await Storage.saveComposerDraft(did, `social-draft:${id}`, edited);
  hook = harness(remote[0]); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.segments[0].text).toBe("Unsynced local edit");
  const media = hook.result.current.segments[0].media;
  if (media?.kind !== "photos") throw new Error("Missing Local Photo");
  expect(media.photos[0].alt).toBe("Unsynced description");
  expect(Attachments.downloadDraftAttachment).not.toHaveBeenCalled();
});
it("reconciles an unknown native create before committing its uploaded photo manifest", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments()));
  const create = implementation(Transport.createSocialDraft);
  const lost = spyOn(Transport, "createSocialDraft").mockImplementation(async args => { await create(args); throw new Error("Native Response Lost"); }); restores.push(() => lost.mockRestore());
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Native Response Lost"); });
  expect(manifests.size).toBe(0); expect(files.size).toBe(2);
  expect((await Storage.loadComposerDraft(did, "new-post"))?.cloud?.createIntent).toBeDefined();
  await act(async () => hook.result.current.retry());
  expect(lost).toHaveBeenCalledTimes(1); expect(manifests.size).toBe(1); expect(files.size).toBe(2);
  expect(hook.result.current.status).toBe("Draft Saved");
});
it("keeps the original manifest's shared files when a confirmed fork is published and cleaned", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments())); await act(async () => hook.result.current.flush());
  const originalId = hook.result.current.cloudId!; const originalManifest = structuredClone(manifests.get(originalId)!);
  act(() => hook.result.current.setSegments(previous => previous.map(segment => ({ ...segment, text: "Fork edit" }))));
  remote = remote.map(item => view(item.id, { ...item.draft, posts: item.draft.posts.map(post => ({ ...post, text: "Remote edit" })) }));
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Changed On Another Device"); });
  await act(async () => hook.result.current.forkLocal()); const forkId = hook.result.current.cloudId!;
  expect(manifests.get(forkId)?.attachments.map(ref => ref.assetId).sort()).toEqual(originalManifest.attachments.map(ref => ref.assetId).sort());
  await act(async () => hook.result.current.clear());
  expect(manifests.get(forkId)?.deleted).toBe(true);
  expect(manifests.get(originalId)).toEqual(originalManifest); expect(files.size).toBe(2);
});

it("commits a new photo draft when the first real manifest response is HTTP 404", async () => {
  const gateway = spyOn(Gateway, "gatewayFetch").mockImplementation(async (_session, path) => {
    expect(path).toContain("/xrpc/app.thesocialwire.socialDraft.getManifest?draftId=");
    return new Response(null, { status: 404 });
  }); restores.push(() => gateway.mockRestore());
  const get = spyOn(Attachments, "getDraftAttachmentManifest").mockImplementation(realGetManifest); restores.push(() => get.mockRestore());
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments()));
  await act(async () => hook.result.current.flush());
  expect(gateway).toHaveBeenCalledTimes(1);
  expect(Attachments.putDraftAttachmentManifest).toHaveBeenCalledWith(expect.anything(), hook.result.current.cloudId, 0, expect.any(Array));
  expect(manifests.get(hook.result.current.cloudId!)?.revision).toBe(1);
  expect(hook.result.current.status).toBe("Draft Saved");
});

function privateGifSegments(): ThreadSegment[] {
  return [{ id: "gif-post", text: "Private animation", media: { kind: "gif", alt: "A celebratory animation", asset: { id: "catalog-123", title: "Celebration", description: "Dancing", attribution: "Powered by KLIPY", url: "https://static.klipy.com/ii/catalog/full.gif", poster: "https://static.klipy.com/ii/catalog/poster.jpg", mp4: "https://static.klipy.com/ii/catalog/video.mp4", webm: "https://static.klipy.com/ii/catalog/video.webm", width: 100, height: 200 } } }];
}
it("recovers all GIF bytes and catalog metadata on a fresh browser with no photo references", async () => {
  let hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privateGifSegments())); await act(async () => hook.result.current.flush());
  const id = hook.result.current.cloudId!; const native = remote.find(view => view.id === id)!;
  expect(hook.result.current.status).toBe("Draft Saved"); expect(manifests.get(id)?.attachments.map(ref => ref.role).sort()).toEqual(["gif", "poster", "video", "video"]);
  expect(manifests.get(id)?.attachments.every(ref => ref.ref.length <= 512)).toBe(true);
  expect(new Set(manifests.get(id)?.attachments.map(ref => ref.ref.split("/").at(-1))).size).toBe(4);
  expect(JSON.stringify(native)).not.toContain("blob:"); expect(native.draft.posts[0].embedImages).toBeUndefined(); hook.unmount();
  await Storage.saveComposerDraft(did, "new-post"); await Storage.saveComposerDraft(did, `social-draft:${id}`);
  const retrieval = spyOn(Klipy, "getGifFile").mockRejectedValue(new Error("Provider Must Not Be Needed")); retrieval.mockClear(); restores.push(() => retrieval.mockRestore());
  hook = harness(native); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  const media = hook.result.current.segments[0].media;
  if (media?.kind !== "gif") throw new Error("Missing GIF");
  expect(media.asset).toEqual((privateGifSegments()[0].media as typeof media).asset); expect(media.alt).toBe("A celebratory animation");
  for (const rendition of ["gif", "poster", "mp4", "webm"] as const) expect(await media.privateFiles?.files[rendition]?.blob.text()).toBe(`catalog-123:${rendition}`);
  expect(retrieval).not.toHaveBeenCalled(); expect(hook.result.current.hasUnavailableMedia).toBe(false);
});
it("restores catalog identity from a GIF-only manifest even when native metadata contains just its URI", async () => {
  let hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privateGifSegments())); await act(async () => hook.result.current.flush()); const id = hook.result.current.cloudId!;
  const native = remote[0]; const uri = native.draft.posts[0].embedExternals![0].uri; hook.unmount();
  await Storage.saveComposerDraft(did, "new-post"); await Storage.saveComposerDraft(did, `social-draft:${id}`);
  const imported = view(id, { posts: [{ text: "Imported", embedExternals: [{ uri }] }] }); remote = [imported]; hook = harness(imported);
  await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  const media = hook.result.current.segments[0].media;
  if (media?.kind !== "gif") throw new Error("Missing GIF");
  expect(media.asset.id).toBe("catalog-123"); expect(media.privateFiles?.files.gif?.blob).toBeInstanceOf(Blob); expect(hook.result.current.hasUnavailableMedia).toBe(false);
});
it("keeps every GIF byte and stable ID checkpoint when a rendition upload fails", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privateGifSegments())); const upload = implementation(Attachments.uploadDraftAttachment);
  const fail = spyOn(Attachments, "uploadDraftAttachment").mockImplementation(async (...args) => { if (args[1].kind === "video") throw new Error("Video Rendition Upload Failed"); return upload(...args); }); restores.push(() => fail.mockRestore());
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Video Rendition Upload Failed"); });
  expect(hook.result.current.status).toBe("Draft Saved Locally"); expect(Transport.createSocialDraft).not.toHaveBeenCalled();
  const recovery = (await Storage.loadComposerDraft(did, "new-post"))!.segments[0].media;
  if (recovery?.kind !== "gif") throw new Error("Missing GIF Recovery");
  const ids = Object.values(recovery.privateFiles!.files).map(file => file.asset.assetId).sort(); expect(ids).toHaveLength(4);
  for (const file of Object.values(recovery.privateFiles!.files)) expect(file.blob).toBeInstanceOf(Blob);
  fail.mockImplementation(upload); await act(async () => hook.result.current.retry());
  expect([...files.keys()].sort()).toEqual(ids); expect(Klipy.getGifFile).toHaveBeenCalledTimes(4); expect(hook.result.current.status).toBe("Draft Saved");
});
it("removes GIF manifest references only after the native embed removal is acknowledged", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privateGifSegments())); await act(async () => hook.result.current.flush()); const id = hook.result.current.cloudId!;
  const put = implementation(Attachments.putDraftAttachmentManifest);
  const commit = spyOn(Attachments, "putDraftAttachmentManifest").mockImplementation(async (...args) => { if (!args[3].length) expect(remote.find(item => item.id === id)?.draft.posts[0].embedExternals).toBeUndefined(); return put(...args); }); restores.push(() => commit.mockRestore());
  act(() => hook.result.current.setSegments(previous => previous.map(segment => ({ ...segment, media: undefined }))));
  await act(async () => hook.result.current.flush());
  expect(manifests.get(id)?.attachments).toEqual([]); expect(Attachments.deleteDraftAttachmentManifest).not.toHaveBeenCalled(); expect(hook.result.current.status).toBe("Draft Saved");
});
it("preserves an imported URI-only GIF and blocks publication and unsafe recopy until reselected", async () => {
  const initial = view("imported-gif", { posts: [{ text: "Imported", embedExternals: [{ uri: "https://static.klipy.com/ii/catalog/full.gif?ww=100&hh=200&mp4=video" }] }] }); remote = [initial];
  const hook = harness(initial); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  expect(hook.result.current.hasUnavailableMedia).toBe(true);
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Reselect"); });
  expect(remote[0]).toEqual(initial); expect(Klipy.getGifFile).not.toHaveBeenCalled(); expect(Attachments.uploadDraftAttachment).not.toHaveBeenCalled();
  const { replaceSocialDraftMedia } = await import("@/lib/socialDraftConversion");
  act(() => hook.result.current.setSegments(previous => previous.map(segment => replaceSocialDraftMedia(segment, privateGifSegments()[0].media))));
  await act(async () => hook.result.current.retry());
  expect(hook.result.current.hasUnavailableMedia).toBe(false); expect(hook.result.current.status).toBe("Draft Saved"); expect(manifests.get(initial.id)?.attachments).toHaveLength(4);
});
it.each([false, true])("rotates explicitly retired photo IDs with durable checkpoints on Retry and Fork: fork=%s", async fork => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privatePhotoSegments())); await act(async () => hook.result.current.flush());
  const oldIds = new Set(files.keys()); const upload = implementation(Attachments.uploadDraftAttachment);
  const retire = spyOn(Attachments, "uploadDraftAttachment").mockImplementation(async (actor, asset, blob) => {
    if (oldIds.has(asset.assetId)) throw Object.assign(new Error("Expired"), { status: 409, error: "AssetRetired" });
    const recovery = await Storage.loadComposerDraft(did, "new-post"); const media = recovery?.segments[0].media;
    if (media?.kind !== "photos") throw new Error("Missing Durable Recovery");
    expect([media.photos[0].privateAttachment?.original.assetId, media.photos[0].privateAttachment?.prepared.assetId]).toContain(asset.assetId);
    return upload(actor, asset, blob);
  }); restores.push(() => retire.mockRestore());
  if (fork) await act(async () => hook.result.current.forkLocal()); else await act(async () => hook.result.current.retry());
  const manifest = manifests.get(hook.result.current.cloudId!)!;
  expect(manifest.attachments.every(ref => !oldIds.has(ref.assetId))).toBe(true); expect(hook.result.current.hasConflict).toBe(false); expect(hook.result.current.status).toBe("Draft Saved");
});
it("coalesces an edit and joined autosave made while an acknowledged draft's manifest commit is pending", async () => {
  const hook = harness(); await waitFor(() => expect(hook.result.current.loaded).toBe(true));
  act(() => hook.result.current.setSegments(privateGifSegments())); const put = implementation(Attachments.putDraftAttachmentManifest);
  const commit = spyOn(Attachments, "putDraftAttachmentManifest").mockRejectedValue(new Error("Store Unavailable")); restores.push(() => commit.mockRestore());
  await act(async () => { await expect(hook.result.current.flush()).rejects.toThrow("Store Unavailable"); });
  const gate = deferred<void>(); commit.mockImplementation(async (...args) => { await gate.promise; return put(...args); });
  let saving!: Promise<void>; act(() => { saving = hook.result.current.retry(); });
  await waitFor(() => expect(commit).toHaveBeenCalledTimes(2));
  act(() => hook.result.current.setSegments(previous => previous.map(segment => ({ ...segment, text: "Edited During Manifest Commit" }))));
  await act(async () => new Promise(resolve => setTimeout(resolve, 850)));
  expect(hook.result.current.status).not.toBe("Draft Saved");
  await act(async () => { gate.resolve(); await saving; });
  expect(remote.find(item => item.id === hook.result.current.cloudId)?.draft.posts[0].text).toBe("Edited During Manifest Commit");
  expect(hook.result.current.status).toBe("Draft Saved"); expect(Transport.updateSocialDraft).toHaveBeenCalledTimes(1);
});
