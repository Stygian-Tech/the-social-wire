"use client";

import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from "react";
import type { AppBskyDraftDefs } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ThreadPublication, ThreadSegment } from "@/lib/blueskyThreadClient";
import { loadComposerDraft, saveComposerDraft, type ComposerDraft } from "@/lib/composerDraftStorage";
import { createSocialDraft, deleteSocialDraft, listSocialDrafts, updateSocialDraft } from "@/lib/blueskyDraftClient";
import { segmentsToSocialDraft, socialDraftDeviceId, socialDraftFingerprint, socialDraftHasContent, socialDraftToSegments } from "@/lib/socialDraftConversion";

type Options = {
  ownerDid: string;
  session: OAuthSession | null;
  enabled: boolean;
  initialDraft?: AppBskyDraftDefs.DraftView;
  segments: ThreadSegment[];
  publicationRef: RefObject<ThreadPublication | undefined>;
  restore: (segments: ThreadSegment[]) => void;
  onChanged?: () => void;
};
type Composition = {
  ownerDid: string;
  session: OAuthSession | null;
  context: string;
  cloud: NonNullable<ComposerDraft["cloud"]>;
  controller: AbortController;
  loaded: boolean;
  stopped: boolean;
  cleaned?: boolean;
  release?: () => void;
  lockDone?: Promise<void>;
  conflict?: string;
  conflictingRemote?: AppBskyDraftDefs.DraftView;
  resolving?: boolean;
  inFlight?: Promise<void>;
};
const blank = (): ThreadSegment[] => [{ id: crypto.randomUUID(), text: "" }];
const attempted = (publication?: ThreadPublication) => publication?.segments.some(segment => segment.attempted) ?? false;
const conflictMessage = "This Draft Changed On Another Device. Your Local Copy Is Safe. Reopen The Remote Draft To Resolve The Conflict.";
const uncertainMessage = "Draft Creation Could Not Be Confirmed. Your Local Copy Is Safe. Retry Checks For The Existing Draft Without Creating Another.";
const indexingMessage = "Draft Update Could Not Be Confirmed. Your Local Copy Is Safe. Retry After The Draft List Refreshes.";
// Wait for our own just-closed editor's lock callback to settle before reopening.
// Active editors are never queued here: a concurrent window still fails closed.
const releasingEditors = new Map<string, Promise<void>>();
const unsupportedSettings = (draft?: AppBskyDraftDefs.Draft) => !!draft && (draft.langs !== undefined || draft.threadgateAllow !== undefined || draft.postgateEmbeddingRules !== undefined || draft.posts.some(post => post.labels !== undefined || post.embedRecords !== undefined));

/** Local recovery and the publication journal are authoritative until explicitly cleared. */
export function useSocialComposerDraft(options: Options) {
  const latest = useRef(options);
  const segments = useRef(options.segments);
  const current = useRef<Composition | undefined>(undefined);
  const [loaded, setLoaded] = useState(false);
  const [saving, setSaving] = useState(false);
  const [status, setStatus] = useState("Loading Draft");
  const [storageError, setStorageError] = useState<string>();
  const [syncError, setSyncError] = useState<string>();
  const [cloudId, setCloudId] = useState<string>();
  const [completed, setCompleted] = useState(false);
  const [cleanupPending, setCleanupPending] = useState(false);
  const [hasConflict, setHasConflict] = useState(false);
  const [unsupportedPublishSettings, setUnsupportedPublishSettings] = useState(false);
  useLayoutEffect(() => { latest.current = options; segments.current = options.segments; });

  function guard(run: Composition) {
    if (current.current !== run || run.controller.signal.aborted || latest.current.ownerDid !== run.ownerDid || latest.current.session !== run.session || (run.session && run.session.did !== run.ownerDid)) throw new Error("Your Account Changed. Reopen The Composer.");
  }
  function actor(run: Composition) {
    guard(run);
    if (!run.session) throw new Error("Sign In To Sync This Draft. Your Local Copy Is Safe.");
    return { session: run.session, viewerDid: run.ownerDid, signal: run.controller.signal, assertCurrentActor: () => guard(run) };
  }
  function report(run: Composition, error: unknown) {
    if (current.current === run && !run.controller.signal.aborted) { setSyncError(error instanceof Error ? error.message : "Draft Could Not Be Synced."); setHasConflict(!!run.conflict); setStatus("Draft Saved Locally"); }
  }
  async function persist(run: Composition) {
    guard(run);
    try {
      const publication = latest.current.publicationRef.current;
      if (publication && publication.did !== run.ownerDid) throw new Error("Publication Belongs To Another Account.");
      await saveComposerDraft(run.ownerDid, run.context, { version: 1, did: run.ownerDid, segments: segments.current, publication, cloud: run.cloud });
      guard(run);
      // Mirror as soon as an ID is known, including while new-post is active.
      // Selecting that cloud ID must recover this device's bytes and journal too.
      await persistCloudRecovery(run);
      setUnsupportedPublishSettings(unsupportedSettings(run.cloud.nativeDraft));
      setStorageError(undefined);
    } catch (error) {
      if (current.current === run && !run.controller.signal.aborted) setStorageError("Draft Could Not Be Saved. Keep This Window Open And Retry.");
      throw error;
    }
  }
  async function persistCloudRecovery(run: Composition) {
    guard(run);
    if (!run.cloud.id || run.context === `social-draft:${run.cloud.id}`) return;
    await saveComposerDraft(run.ownerDid, `social-draft:${run.cloud.id}`, { version: 1, did: run.ownerDid, segments: segments.current, publication: latest.current.publicationRef.current, cloud: run.cloud });
    guard(run);
  }
  async function list(run: Composition) {
    const drafts: AppBskyDraftDefs.DraftView[] = [];
    let cursor: string | undefined;
    const cursors = new Set<string>();
    do {
      const page = await listSocialDrafts({ ...actor(run), cursor });
      guard(run);
      drafts.push(...page.drafts);
      cursor = page.cursor;
      if (cursor && cursors.has(cursor)) throw new Error("Draft List Did Not Finish. Retry Before Syncing.");
      if (cursor) cursors.add(cursor);
    } while (cursor);
    return drafts;
  }
  async function acquireEditor(run: Composition) {
    if (!navigator.locks?.request) throw new Error("Exclusive Draft Editing Is Unavailable In This Browser. Use A Browser With Web Locks To Safely Edit Drafts.");
    await releasingEditors.get(run.ownerDid);
    guard(run);
    await new Promise<void>((resolve, reject) => {
      let release!: () => void;
      const held = new Promise<void>(done => { release = done; });
      run.lockDone = navigator.locks.request(`the-social-wire.social-composer:${run.ownerDid}`, { mode: "exclusive", ifAvailable: true }, async lock => {
        if (!lock) throw new Error("This Account's Composer Is Already Open In Another Window. Close It Before Editing Here.");
        guard(run);
        run.release = release;
        resolve();
        await held;
      }).then(() => {}).catch(reject);
    });
    guard(run);
  }
  async function confirmUpdate(run: Composition) {
    const pending = run.cloud.pendingUpdate;
    if (!pending) return;
    const expected = socialDraftFingerprint(pending.draft);
    // Bounded reads never turn an eventually consistent old page into an ack.
    // Transport timeouts bound each request; this does not wait indefinitely.
    for (let attempt = 0; attempt < 3; attempt++) {
      if (attempt) await new Promise<void>((resolve, reject) => {
        const signal = run.controller.signal;
        signal.throwIfAborted();
        const abort = () => { clearTimeout(timer); reject(signal.reason); };
        const timer = setTimeout(() => { signal.removeEventListener("abort", abort); resolve(); }, attempt === 1 ? 400 : 1200);
        signal.addEventListener("abort", abort, { once: true });
      });
      guard(run);
      const remote = (await list(run)).find(view => view.id === run.cloud.id);
      if (remote && socialDraftFingerprint(remote.draft) === expected) {
        run.cloud.stalePayloads = [...(run.cloud.stalePayloads ?? []), socialDraftFingerprint(pending.previous)];
        run.cloud.acknowledged = pending.draft;
        run.cloud.nativeDraft = pending.draft;
        delete run.cloud.pendingUpdate;
        await persist(run);
        return;
      }
      const fingerprint = remote && socialDraftFingerprint(remote.draft);
      if (fingerprint && fingerprint !== socialDraftFingerprint(pending.previous) && !run.cloud.stalePayloads?.includes(fingerprint)) { run.conflict = conflictMessage; run.conflictingRemote = remote; throw new Error(conflictMessage); }
    }
    throw new Error(indexingMessage);
  }
  async function reconcileCreate(run: Composition) {
    const intent = run.cloud.createIntent!;
    const candidates = (await list(run)).filter(view => !intent.baselineIds.includes(view.id) && view.draft.deviceId === intent.draft.deviceId && socialDraftFingerprint(view.draft) === socialDraftFingerprint(intent.draft));
    if (candidates.length !== 1) throw new Error(uncertainMessage);
    run.cloud.id = candidates[0].id;
    run.cloud.acknowledged = intent.draft;
    run.cloud.nativeDraft = intent.draft;
    delete run.cloud.createIntent;
    await persist(run);
    guard(run);
    setCloudId(run.cloud.id);
    latest.current.onChanged?.();
  }
  async function finishFork(run: Composition) {
    const source = run.cloud.forkSource;
    if (!source || !run.cloud.id) return;
    // Only retire the old local conflict after the separate fork is confirmed
    // and durably available under its own cloud ID, including its media bytes.
    await persistCloudRecovery(run);
    await saveComposerDraft(run.ownerDid, `social-draft:${source.id}`, { version: 1, did: run.ownerDid, segments: socialDraftToSegments(source.draft, segments.current), cloud: { id: source.id, deviceId: run.cloud.deviceId, updatedAt: Date.now(), nativeDraft: source.draft, acknowledged: source.draft } });
    guard(run);
    run.context = `social-draft:${run.cloud.id}`;
    await persist(run);
    const activeNewPost = await loadComposerDraft(run.ownerDid, "new-post");
    guard(run);
    if (activeNewPost?.cloud?.id === run.cloud.id) { await saveComposerDraft(run.ownerDid, "new-post"); guard(run); }
    delete run.cloud.forkSource;
    await persist(run);
  }
  async function saveRemote(run: Composition) {
    guard(run);
    if (!run.loaded) throw new Error("Wait For Draft Recovery Before Continuing.");
    if (run.cloud.completed) throw new Error("This Composition Was Already Published. Retry Draft Cleanup.");
    if (run.stopped || run.resolving) return;
    await persist(run);
    if (attempted(latest.current.publicationRef.current)) return;
    if (run.conflict) throw new Error(run.conflict);
    if (run.cloud.createIntent && !run.cloud.id) await reconcileCreate(run);
    if (run.cloud.pendingUpdate) await confirmUpdate(run);
    if (run.cloud.forkSource && run.cloud.id) await finishFork(run);
    for (;;) {
      guard(run);
      if (attempted(latest.current.publicationRef.current) || run.stopped) return;
      if (!run.cloud.id && !socialDraftHasContent(segments.current)) { setStatus("Draft Saved Locally"); return; }
      const payload = segmentsToSocialDraft(segments.current, run.cloud.deviceId, run.cloud.nativeDraft);
      const fingerprint = socialDraftFingerprint(payload);
      if (fingerprint === socialDraftFingerprint(run.cloud.acknowledged)) { setSyncError(undefined); setStatus("Draft Saved"); return; }
      await persist(run);
      if (attempted(latest.current.publicationRef.current) || run.stopped) return;
      if (!run.cloud.id) {
        const baselineIds = (await list(run)).map(view => view.id);
        guard(run);
        if (attempted(latest.current.publicationRef.current) || run.stopped) return;
        run.cloud.createIntent = { draft: payload, baselineIds };
        // Persist intent BEFORE the non-idempotent request, including across reloads.
        await persist(run);
        if (attempted(latest.current.publicationRef.current) || run.stopped) {
          delete run.cloud.createIntent;
          await persist(run);
          return;
        }
        const created = await createSocialDraft({ ...actor(run), draft: payload });
        guard(run);
        run.cloud.id = created.id;
        run.cloud.acknowledged = payload;
        run.cloud.nativeDraft = payload;
        // Keep the intent durable until the acknowledged ID is durably saved.
        await persist(run);
        delete run.cloud.createIntent;
        await persist(run);
        setCloudId(created.id);
      } else {
        const remote = (await list(run)).find(view => view.id === run.cloud.id);
        if (!remote) throw new Error("The Saved Draft Is Not Available Yet Or Was Deleted. Your Local Copy Is Safe. Retry After The Draft List Refreshes.");
        const remoteFingerprint = remote && socialDraftFingerprint(remote.draft);
        // Acknowledged payload history tolerates eventual-consistency reads. It is
        // never restored over local edits. The upstream API has no atomic CAS.
        if (remoteFingerprint && remoteFingerprint !== socialDraftFingerprint(run.cloud.acknowledged) && !run.cloud.stalePayloads?.includes(remoteFingerprint)) {
          run.conflict = conflictMessage;
          run.conflictingRemote = remote;
          throw new Error(conflictMessage);
        }
        guard(run);
        if (attempted(latest.current.publicationRef.current) || run.stopped) return;
        run.cloud.pendingUpdate = { draft: payload, previous: run.cloud.acknowledged };
        await persist(run);
        await updateSocialDraft({ ...actor(run), id: run.cloud.id, draft: payload });
        guard(run);
        await confirmUpdate(run);
      }
      latest.current.onChanged?.();
      if (run.cloud.forkSource && run.cloud.id) await finishFork(run);
      // Edits made during the request are coalesced into the next serialized save.
    }
  }
  function flushRun(run: Composition): Promise<void> {
    if (run.inFlight) return run.inFlight;
    setSaving(true);
    const promise = saveRemote(run).catch(error => { report(run, error); throw error; }).finally(() => {
      if (run.inFlight === promise) run.inFlight = undefined;
      if (current.current === run) setSaving(false);
    });
    run.inFlight = promise;
    return promise;
  }

  useEffect(() => {
    if (!options.enabled) return;
    const run: Composition = { ownerDid: options.ownerDid, session: options.session, context: options.initialDraft ? `social-draft:${options.initialDraft.id}` : "new-post", cloud: { deviceId: "", updatedAt: Date.now() }, controller: new AbortController(), loaded: false, stopped: false };
    current.current = run;
    void (async () => {
      // Reset and restore together in the asynchronous recovery operation. An
      // immediately closed/replaced composition cannot reset its successor.
      await Promise.resolve();
      guard(run);
      setLoaded(false); setSaving(false); setCloudId(undefined); setCompleted(false); setCleanupPending(false); setHasConflict(false); setUnsupportedPublishSettings(false); setStorageError(undefined); setSyncError(undefined); setStatus("Loading Draft");
      await acquireEditor(run);
      run.cloud.deviceId = socialDraftDeviceId();
      const local = await loadComposerDraft(run.ownerDid, run.context);
      guard(run);
      let restored = blank();
      latest.current.publicationRef.current = undefined;
      const initial = latest.current.initialDraft;
      if (local && (!initial || local.cloud?.id === initial.id)) {
        run.cloud = local.cloud ?? run.cloud;
        run.cleaned = !!run.cloud.cleaned;
        run.stopped = !!run.cloud.completed;
        if (!run.cloud.completed) {
          restored = local.segments;
          latest.current.publicationRef.current = local.publication;
          if (initial && run.cloud.acknowledged && socialDraftFingerprint(initial.draft) !== socialDraftFingerprint(run.cloud.acknowledged) && socialDraftFingerprint(initial.draft) !== socialDraftFingerprint(run.cloud.pendingUpdate?.draft) && !run.cloud.stalePayloads?.includes(socialDraftFingerprint(initial.draft))) {
            const localPayload = segmentsToSocialDraft(local.segments, run.cloud.deviceId, run.cloud.nativeDraft);
            const hasUnsyncedRecovery = socialDraftFingerprint(localPayload) !== socialDraftFingerprint(run.cloud.acknowledged);
            if (!hasUnsyncedRecovery && !local.publication && !run.cloud.createIntent) {
              // No pending local changes: resume the current remote version,
              // retaining any locally available files that its references match.
              restored = socialDraftToSegments(initial.draft, local.segments);
              run.cloud.nativeDraft = structuredClone(initial.draft);
              run.cloud.acknowledged = structuredClone(initial.draft);
            } else { run.conflict = conflictMessage; run.conflictingRemote = initial; }
          }
        }
      } else if (initial) {
        run.cloud.id = initial.id;
        run.cloud.nativeDraft = structuredClone(initial.draft);
        run.cloud.acknowledged = structuredClone(initial.draft);
        restored = socialDraftToSegments(initial.draft);
      }
      segments.current = restored;
      latest.current.restore(restored);
      run.loaded = true;
      setUnsupportedPublishSettings(unsupportedSettings(run.cloud.nativeDraft));
      setCompleted(!!run.cloud.completed); setCleanupPending(!!run.cloud.completed && !run.cleaned);
      setCloudId(run.cloud.id); setLoaded(true); setStatus(run.cleaned ? "Published" : run.cloud.completed ? "Published Draft Cleanup Pending" : "Draft Saved Locally");
      if (run.conflict) setSyncError(run.conflict);
      setHasConflict(!!run.conflict);
      if (run.cloud.createIntent) setSyncError(uncertainMessage);
      await persist(run);
    })().catch(error => {
      if (current.current === run && !run.controller.signal.aborted) { setStorageError(error instanceof Error ? error.message : "Draft Could Not Be Restored."); setStatus("Draft Recovery Failed"); }
    });
    return () => {
      run.controller.abort(); run.release?.();
      if (run.lockDone) {
        const released = run.lockDone;
        releasingEditors.set(run.ownerDid, released);
        void released.finally(() => { if (releasingEditors.get(run.ownerDid) === released) releasingEditors.delete(run.ownerDid); });
      }
      if (current.current === run) current.current = undefined;
    };
    // The remote ID identifies an editing session; list object refreshes cannot reset it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [options.enabled, options.ownerDid, options.session, options.initialDraft?.id]);

  useEffect(() => {
    const run = current.current;
    if (!options.enabled || !loaded || !run?.loaded || run.stopped || run.cloud.completed) return;
    run.cloud.updatedAt = Date.now();
    void persist(run).catch(() => {});
    if (attempted(options.publicationRef.current)) return;
    const timer = setTimeout(() => { void flushRun(run).catch(() => {}); }, 800);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [options.segments, options.enabled, loaded]);

  function active() {
    const run = current.current;
    if (!run?.loaded) throw new Error("Wait For Draft Recovery Before Continuing.");
    guard(run);
    return run;
  }
  async function checkpoint() { await persist(active()); }
  async function flush() { await flushRun(active()); }
  async function cleanupPublished(run: Composition) {
    if (run.cleaned) return;
    await persist(run);
    if (run.cloud.createIntent && !run.cloud.id) await reconcileCreate(run);
    // The cloud recovery context may be what a later remote-list selection opens.
    await persistCloudRecovery(run);
    // A cloud editor can have been opened while its original new-post recovery
    // still exists. Mark that matching copy before deleting anything remotely.
    const activeNewPost = run.context !== "new-post" && run.cloud.id ? await loadComposerDraft(run.ownerDid, "new-post") : undefined;
    guard(run);
    const matchingNewPost = !!activeNewPost && activeNewPost.cloud?.id === run.cloud.id;
    if (matchingNewPost) {
      await saveComposerDraft(run.ownerDid, "new-post", { ...activeNewPost!, cloud: { ...activeNewPost!.cloud!, completed: true } });
      guard(run);
    }
    if (run.cloud.id) { await deleteSocialDraft({ ...actor(run), id: run.cloud.id }); guard(run); }
    if (run.cloud.id) {
      // Keep a compact tombstone: eventual list reads may still return the draft
      // after deletion. Reopening it on this device must never publish it again.
      await saveComposerDraft(run.ownerDid, `social-draft:${run.cloud.id}`, { version: 1, did: run.ownerDid, segments: blank(), cloud: { id: run.cloud.id, deviceId: run.cloud.deviceId, updatedAt: Date.now(), completed: true, cleaned: true } });
      guard(run);
    }
    if (!run.cloud.id || run.context !== `social-draft:${run.cloud.id}`) { await saveComposerDraft(run.ownerDid, run.context); guard(run); }
    if (matchingNewPost) { await saveComposerDraft(run.ownerDid, "new-post"); guard(run); }
    run.stopped = true;
    run.cleaned = true;
    setCompleted(true); setCleanupPending(false);
    setCloudId(undefined); setSyncError(undefined); setStatus("Published");
    latest.current.onChanged?.();
  }
  async function clear() {
    const run = active();
    if (run.cleaned) return;
    run.stopped = true;
    // This marker is written even if an in-flight save or deletion later fails.
    run.cloud.completed = true;
    setCompleted(true); setCleanupPending(true);
    await persist(run);
    await persistCloudRecovery(run);
    await run.inFlight?.catch(() => {});
    await persist(run);
    await persistCloudRecovery(run);
    try { await cleanupPublished(run); } catch (error) { report(run, error); throw error; }
  }
  async function close() {
    // A failed exclusive-lock/recovery initialization has never admitted edits.
    if (!current.current?.loaded) return;
    const run = active();
    if (run.cleaned) return;
    await flushRun(run);
    guard(run);
    if (attempted(latest.current.publicationRef.current)) return;
    const payload = segmentsToSocialDraft(segments.current, run.cloud.deviceId, run.cloud.nativeDraft);
    if (!run.cloud.id && !socialDraftHasContent(segments.current) || run.cloud.id && socialDraftFingerprint(payload) === socialDraftFingerprint(run.cloud.acknowledged)) {
      run.stopped = true;
      await persistCloudRecovery(run);
      if (!run.cloud.id || run.context !== `social-draft:${run.cloud.id}`) await saveComposerDraft(run.ownerDid, run.context);
      guard(run);
      segments.current = blank();
      latest.current.restore(segments.current);
    } else throw new Error("Draft Has Unsynced Changes. Keep The Composer Open And Retry.");
  }
  async function retry() {
    const run = active();
    if (run.cloud.completed) {
      try { await cleanupPublished(run); } catch (error) { report(run, error); throw error; }
    } else await flushRun(run);
  }
  async function preserveConflictCopy(run: Composition) {
    const context = `social-conflict:${run.cloud.id ?? "new"}:${crypto.randomUUID()}`;
    await saveComposerDraft(run.ownerDid, context, { version: 1, did: run.ownerDid, segments: segments.current, publication: latest.current.publicationRef.current, cloud: { ...run.cloud, conflictCopyContext: context } });
    guard(run);
    return context;
  }
  async function forkLocal() {
    const run = active();
    if (run.cloud.completed || attempted(latest.current.publicationRef.current)) throw new Error("Published Or Attempted Compositions Cannot Be Forked.");
    run.resolving = true; setSaving(true);
    try {
      await run.inFlight?.catch(() => {});
      guard(run);
      const context = await preserveConflictCopy(run);
      const nativeDraft = segmentsToSocialDraft(segments.current, run.cloud.deviceId, run.cloud.nativeDraft);
      const forkSource = run.cloud.id ? { id: run.cloud.id, draft: run.conflictingRemote?.draft ?? run.cloud.acknowledged ?? nativeDraft } : undefined;
      const deviceId = socialDraftDeviceId();
      run.cloud = { deviceId, updatedAt: Date.now(), nativeDraft: { ...nativeDraft, deviceId }, conflictCopyContext: context, forkSource };
      run.context = "new-post";
      run.conflict = undefined; run.conflictingRemote = undefined;
      // Forking never carries prepared PDS records or keys into the new draft.
      latest.current.publicationRef.current = undefined;
      await persist(run);
      setCloudId(undefined); setSyncError(undefined); setHasConflict(false);
    } catch (error) { report(run, error); throw error; }
    finally { run.resolving = false; if (current.current === run) setSaving(false); }
    await flushRun(run);
  }
  async function openRemote() {
    const run = active();
    if (run.cloud.completed || attempted(latest.current.publicationRef.current)) throw new Error("Published Or Attempted Compositions Cannot Be Replaced.");
    if (!run.cloud.id) throw new Error("There Is No Confirmed Remote Draft To Open.");
    const originalId = run.cloud.id;
    const originalConflict = run.conflictingRemote;
    // A remote fork makes the preserved local content discoverable in Drafts,
    // rather than leaving its only recovery in an opaque IndexedDB context.
    await forkLocal();
    guard(run);
    run.resolving = true; setSaving(true);
    try {
      await run.inFlight?.catch(() => {});
      const listed = (await list(run)).find(view => view.id === originalId);
      if (!listed) throw new Error("The Remote Draft Is Not Available. Your Local Copy Is Safe.");
      const remote = originalConflict && Date.parse(originalConflict.updatedAt) > Date.parse(listed.updatedAt) ? originalConflict : listed;
      const context = await preserveConflictCopy(run);
      const restored = socialDraftToSegments(remote.draft, segments.current);
      run.cloud = { id: remote.id, deviceId: run.cloud.deviceId, updatedAt: Date.now(), nativeDraft: structuredClone(remote.draft), acknowledged: structuredClone(remote.draft), conflictCopyContext: context };
      run.context = `social-draft:${remote.id}`;
      run.conflict = undefined; run.conflictingRemote = undefined;
      latest.current.publicationRef.current = undefined;
      segments.current = restored;
      await persist(run);
      latest.current.restore(restored);
      setCloudId(remote.id); setSyncError(undefined); setHasConflict(false); setStatus("Draft Saved");
    } catch (error) { report(run, error); throw error; }
    finally { run.resolving = false; if (current.current === run) setSaving(false); }
  }
  return { loaded: options.enabled && loaded, saving, status, storageError, syncError, cloudId, completed, cleanupPending, hasConflict, unsupportedPublishSettings, checkpoint, flush, clear, close, retry, forkLocal, openRemote, hasUnavailableMedia: options.segments.some(segment => !!segment.unavailableDraftMedia) };
}
