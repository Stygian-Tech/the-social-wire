import type { OAuthSession } from "@atproto/oauth-client-browser";
import { deleteSocialDraft, listSocialDrafts } from "./blueskyDraftClient";
import { loadComposerDraft, saveComposerDraft, type ComposerDraft } from "./composerDraftStorage";
import { deleteDraftAttachmentManifest, getDraftAttachmentManifest } from "./socialDraftAttachmentClient";
import { hasDraftGifs, hasPrivateDraftPhotos, socialDraftFingerprint } from "./socialDraftConversion";

type Actor = { session: OAuthSession; viewerDid: string; signal?: AbortSignal; assertCurrentActor: () => void };

/** Archive completion before freeing the editor. Unknown creates retain their intent. */
export async function archivePublishedComposition(ownerDid: string, context: string, draft: ComposerDraft, guard: () => void): Promise<string> {
  guard();
  const recoveryContext = `publication-cleanup:${crypto.randomUUID()}`;
  const completed = { ...draft, cloud: { ...draft.cloud!, completed: true } };
  await saveComposerDraft(ownerDid, recoveryContext, completed);
  guard();
  if (draft.cloud?.id) {
    await saveComposerDraft(ownerDid, `social-draft:${draft.cloud.id}`, completed);
    guard();
  }
  // The recovery slot and cloud tombstone are durable before New Post is freed.
  if (context !== `social-draft:${draft.cloud?.id}`) await saveComposerDraft(ownerDid, context);
  guard();
  return recoveryContext;
}

/** Cleanup cannot prepare or publish posts. Every step is resumable from local authority. */
export async function cleanupPublishedComposition(actor: Actor, context: string, draft: ComposerDraft): Promise<void> {
  const guard = () => { actor.signal?.throwIfAborted(); actor.assertCurrentActor(); };
  const cloud = draft.cloud;
  guard();
  if (!cloud?.completed || actor.viewerDid !== draft.did || actor.session.did !== draft.did) throw new Error("Invalid Publication Cleanup Owner.");
  const persist = async () => { guard(); await saveComposerDraft(draft.did, context, draft); guard(); };
  if (cloud.createIntent && !cloud.id) {
    const intent = cloud.createIntent;
    const candidates = [];
    const cursors = new Set<string>();
    let cursor: string | undefined;
    do {
      const page = await listSocialDrafts({ ...actor, cursor });
      guard();
      candidates.push(...page.drafts.filter(view => !intent.baselineIds.includes(view.id) && view.draft.deviceId === intent.draft.deviceId && socialDraftFingerprint(view.draft) === socialDraftFingerprint(intent.draft)));
      cursor = page.cursor;
      if (cursor && cursors.has(cursor)) throw new Error("Draft List Did Not Finish.");
      if (cursor) cursors.add(cursor);
    } while (cursor);
    if (candidates.length !== 1) throw new Error("Published Draft Creation Still Needs Reconciliation.");
    cloud.id = candidates[0].id;
    cloud.nativeDraft = intent.draft;
    await persist();
    delete cloud.createIntent;
    await persist();
  }
  if (cloud.id) {
    // Persist identity and the completion tombstone before destructive requests.
    await saveComposerDraft(draft.did, `social-draft:${cloud.id}`, draft);
    guard();
    if (!cloud.nativeDeleted) {
      await deleteSocialDraft({ ...actor, id: cloud.id });
      guard();
      cloud.nativeDeleted = true;
      await persist();
    }
    if (cloud.attachmentManifest || cloud.pendingManifest || hasPrivateDraftPhotos(cloud.nativeDraft) || hasDraftGifs(cloud.nativeDraft)) {
      const manifest = await getDraftAttachmentManifest(actor, cloud.id);
      guard();
      if (!manifest.deleted) await deleteDraftAttachmentManifest(actor, cloud.id, manifest.revision);
      guard();
    }
    await saveComposerDraft(draft.did, `social-draft:${cloud.id}`, { version: 1, did: draft.did, segments: [{ id: "completed", text: "" }], cloud: { id: cloud.id, deviceId: cloud.deviceId, updatedAt: Date.now(), completed: true, cleaned: true } });
    guard();
    // An older editor may have left a matching New Post recovery copy. Never
    // remove a successor composition merely because cleanup finished later.
    const active = await loadComposerDraft(draft.did, "new-post");
    guard();
    if (active?.cloud?.completed && active.cloud.id === cloud.id) { await saveComposerDraft(draft.did, "new-post"); guard(); }
  }
  await saveComposerDraft(draft.did, context);
  guard();
}
