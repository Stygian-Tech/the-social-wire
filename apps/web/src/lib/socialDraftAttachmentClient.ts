import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gatewayFetch } from "./socialWireGatewayClient";
import { awaitWithAbort } from "./awaitWithAbort";

export type DraftAttachmentActor = {
  session: OAuthSession; viewerDid: string; signal?: AbortSignal; assertCurrentActor?: () => void;
};
export type DraftAttachment = {
  assetId: string; name: string; contentType: string; byteLength: number; sha256: string;
  kind: "photo" | "video" | "gif" | "poster" | "caption"; state: "reserved" | "ready";
};
export type DraftAttachmentRef = { assetId: string; role: "original" | "prepared" | "video" | "poster" | "caption" | "gif"; ref: string };
export type DraftAttachmentManifest = { draftId: string; revision: number; deleted: boolean; attachments: (DraftAttachmentRef & { asset: DraftAttachment })[] };
export const PRIVATE_DRAFT_FILE_LIMIT = 100 * 1024 * 1024;
const prefix = "/xrpc/app.thesocialwire.socialDraft.";
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function assertDraftAttachmentActor(actor: DraftAttachmentActor) {
  actor.signal?.throwIfAborted();
  if (!actor.viewerDid || actor.session.did !== actor.viewerDid) throw new Error("Your Account Changed. Reopen The Composer.");
  actor.assertCurrentActor?.();
}
function validateAsset(value: DraftAttachment): DraftAttachment {
  if (!value || !uuid.test(value.assetId) || typeof value.name !== "string" || !value.name || typeof value.contentType !== "string" || !/^[\w.+-]+\/[\w.+-]+$/.test(value.contentType) || !Number.isSafeInteger(value.byteLength) || value.byteLength <= 0 || value.byteLength > PRIVATE_DRAFT_FILE_LIMIT || !/^[0-9a-f]{64}$/.test(value.sha256) || !["photo", "video", "gif", "poster", "caption"].includes(value.kind) || !["reserved", "ready"].includes(value.state)) throw new Error("Invalid Private Draft Attachment Metadata.");
  return value;
}
function validateRevision(revision: number) {
  if (!Number.isSafeInteger(revision) || revision < 0) throw new Error("Invalid Private Draft Manifest Revision.");
}
function validateRefs(refs: DraftAttachmentRef[]) {
  if (!Array.isArray(refs) || refs.some(ref => !uuid.test(ref.assetId) || typeof ref.ref !== "string" || !ref.ref || ref.ref.length > 512 || !["original", "prepared", "video", "poster", "caption", "gif"].includes(ref.role))) throw new Error("Invalid Private Draft Attachment Reference.");
}
function validateManifest(value: DraftAttachmentManifest, draftId: string) {
  if (!value || value.draftId !== draftId || !Number.isSafeInteger(value.revision) || value.revision < 0 || typeof value.deleted !== "boolean") throw new Error("Invalid Private Draft Manifest.");
  validateRefs(value.attachments);
  for (const ref of value.attachments) if (validateAsset(ref.asset).assetId !== ref.assetId) throw new Error("Private Draft Manifest Asset Does Not Match.");
  return value;
}
async function request<T>(actor: DraftAttachmentActor, method: string, init: RequestInit, decode: (response: Response) => Promise<T>, acceptNotFound = false): Promise<T> {
  assertDraftAttachmentActor(actor);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error("Private Attachment Sync Timed Out. Your Local Copy Is Safe. Retry.")), 60_000);
  const signal = actor.signal ? AbortSignal.any([actor.signal, controller.signal]) : controller.signal;
  try {
    return await awaitWithAbort((async () => {
      const response = await gatewayFetch(actor.session, `${prefix}${method}`, { ...init, signal, cache: "no-store", redirect: "error" });
      assertDraftAttachmentActor(actor);
      if (!response.ok && !(acceptNotFound && response.status === 404)) throw Object.assign(new Error(response.status === 409 ? "Private Draft Attachments Changed On Another Device. Reopen The Remote Draft Or Save A Copy." : "Private Draft Attachment Sync Failed. Your Local Copy Is Safe. Retry."), { status: response.status });
      const result = await decode(response);
      assertDraftAttachmentActor(actor);
      return result;
    })(), signal);
  } finally { clearTimeout(timer); assertDraftAttachmentActor(actor); }
}
const json = (body: unknown): RequestInit => ({ method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
export async function draftAttachmentSHA256(blob: Blob): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", await blob.arrayBuffer())), byte => byte.toString(16).padStart(2, "0")).join("");
}
export async function describeDraftAttachment(blob: Blob, name: string, previous?: DraftAttachment): Promise<DraftAttachment> {
  const metadata = { assetId: previous?.assetId ?? "", name, contentType: blob.type, byteLength: blob.size, sha256: await draftAttachmentSHA256(blob), kind: "photo" as const, state: "reserved" as const };
  const matches = previous && ["name", "contentType", "byteLength", "sha256", "kind"].every(key => previous[key as keyof DraftAttachment] === metadata[key as keyof DraftAttachment]);
  return validateAsset(matches ? previous : { ...metadata, assetId: crypto.randomUUID() });
}
function sameFile(a: DraftAttachment, b: DraftAttachment) {
  return ["assetId", "name", "contentType", "byteLength", "sha256", "kind"].every(key => a[key as keyof DraftAttachment] === b[key as keyof DraftAttachment]);
}
export async function uploadDraftAttachment(actor: DraftAttachmentActor, asset: DraftAttachment, blob: Blob): Promise<DraftAttachment> {
  validateAsset(asset);
  if (blob.size !== asset.byteLength || blob.type !== asset.contentType || await draftAttachmentSHA256(blob) !== asset.sha256) throw new Error("Private Draft File Changed. Retry Saving The Photo.");
  const metadata = { assetId: asset.assetId, name: asset.name, contentType: asset.contentType, byteLength: asset.byteLength, sha256: asset.sha256, kind: asset.kind };
  const decode = async (response: Response) => {
    const result = validateAsset((await response.json()).attachment);
    if (!sameFile(asset, result)) throw new Error("Private Draft Upload Metadata Does Not Match.");
    return result;
  };
  const reserved = await request(actor, "reserveAttachment", json(metadata), decode);
  if (reserved.state === "ready") return reserved;
  // Blob bodies let the browser set Content-Length without a forbidden header.
  const uploaded = await request(actor, "uploadAttachment", { method: "POST", headers: { "Content-Type": "application/octet-stream", "X-Social-Draft-Upload-Id": asset.assetId }, body: blob }, decode);
  if (uploaded.state !== "ready") throw new Error("Private Draft Photo Upload Is Pending. Retry Before Closing.");
  return uploaded;
}
export async function getDraftAttachmentManifest(actor: DraftAttachmentActor, draftId: string) {
  return request(actor, `getManifest?draftId=${encodeURIComponent(draftId)}`, {}, async response => response.status === 404
    ? { draftId, revision: 0, deleted: false, attachments: [] }
    : validateManifest(await response.json(), draftId), true);
}
export async function putDraftAttachmentManifest(actor: DraftAttachmentActor, draftId: string, expectedRevision: number, attachments: DraftAttachmentRef[]) {
  validateRevision(expectedRevision);
  validateRefs(attachments);
  return request(actor, "putManifest", json({ draftId, expectedRevision, attachments }), async response => validateManifest(await response.json(), draftId));
}
/** Call only after native publication/deletion is confirmed. A failure must retain the local completion marker. */
export async function deleteDraftAttachmentManifest(actor: DraftAttachmentActor, draftId: string, expectedRevision: number) {
  validateRevision(expectedRevision);
  return request(actor, "deleteManifest", json({ draftId, expectedRevision }), async response => {
    const manifest = validateManifest(await response.json(), draftId);
    if (!manifest.deleted) throw new Error("Private Draft Attachment Cleanup Is Pending. Retry.");
    return manifest;
  });
}
export async function downloadDraftAttachment(actor: DraftAttachmentActor, asset: DraftAttachment): Promise<Blob> {
  validateAsset(asset);
  if (asset.state !== "ready") throw new Error("Private Draft Photo Is Still Uploading. Retry After Saving On The Original Device.");
  return request(actor, `getAttachment?assetId=${encodeURIComponent(asset.assetId)}`, { headers: { Accept: asset.contentType } }, async response => {
    const blob = await response.blob();
    if (blob.type !== asset.contentType || blob.size !== asset.byteLength || await draftAttachmentSHA256(blob) !== asset.sha256) throw new Error("Private Draft Photo Verification Failed. Retry Or Reattach The Photo.");
    return blob;
  });
}
