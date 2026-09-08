import { CHUNK_COLLECTION, MANIFEST_COLLECTION, MAX_RECORD_BYTES, ReadStateError, type Operation, type Reference } from "./types";
import { jsonBytes, validateOperation, validateReference } from "./validation";
import type { DeviceReceipt, LegacyActionReceipt } from "./v2Foundation";
import type { V2Chunk, V2Fragment, V2Manifest } from "./v2Types";

export function v2Require(value: unknown): asserts value { if (!value) throw new ReadStateError("invalid_record"); }
export function v2Known(value: object, fields: string[]): void {
  v2Require(value && typeof value === "object" && !Array.isArray(value));
  if (Object.keys(value).some(key => !fields.includes(key))) throw new ReadStateError("invalid_record", "Unsupported v2 fields; preserve this generation without rewriting it.");
}
export const safeCounter = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
export const hashValue = (value: unknown): value is string => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
export const deviceIdValue = (value: unknown): value is string => typeof value === "string" && /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/.test(value);
const shortText = (value: unknown) => typeof value === "string" && value.length > 0 && new TextEncoder().encode(value).length <= 128;
function reference(value: Reference, viewer: string) { v2Known(value, ["uri", "cid"]); validateReference(value, viewer); }
export function fragmentOperation(fragment: V2Fragment): Operation {
  const { fragment: _, intentHash: _hash, deviceId: _device, deviceCounter: _counter, ...operation } = fragment;
  return operation;
}
export function validateV2Manifest(value: unknown, viewer: string): asserts value is V2Manifest {
  const manifest = value as V2Manifest;
  v2Known(manifest, ["$type", "version", "generation", "revision", "lastSequence", "compactionVersion", "stateHead", "devicesHead", "legacyReceiptsHead"]);
  v2Require(manifest.$type === MANIFEST_COLLECTION && manifest.version === 2 && manifest.compactionVersion === 1
    && shortText(manifest.generation) && safeCounter(manifest.revision) && manifest.revision > 0 && safeCounter(manifest.lastSequence));
  for (const root of [manifest.stateHead, manifest.devicesHead, manifest.legacyReceiptsHead]) if (root !== undefined) reference(root, viewer);
  if (jsonBytes(manifest) > MAX_RECORD_BYTES) throw new ReadStateError("size_limit");
}
export function validateV2Fragment(value: V2Fragment): void {
  v2Known(value, ["fragment", "intentHash", "deviceId", "deviceCounter", "actionId", "sequence", "state", "actedAt", "selection", "calendar", "subjectUris", "boundaries"]);
  v2Require(value.fragment === true && hashValue(value.intentHash));
  v2Require((value.deviceId === undefined && value.deviceCounter === undefined)
    || (deviceIdValue(value.deviceId) && safeCounter(value.deviceCounter) && value.deviceCounter > 0));
  validateOperation(fragmentOperation(value));
  if (value.calendar) v2Known(value.calendar, ["cutoff", "timeZone", "referenceDate"]);
  for (const boundary of value.boundaries ?? []) {
    v2Known(boundary, ["scope", "createdAt", "entryId"]);
    v2Known(boundary.scope, ["publicationId", "authorDid", "publicationSiteKeys"]);
  }
}
export function validateV2DeviceReceipt(value: DeviceReceipt): void {
  v2Known(value, ["deviceId", "committedCounter", "prefixHash"]);
  v2Require(deviceIdValue(value.deviceId) && safeCounter(value.committedCounter) && hashValue(value.prefixHash));
}
export function validateV2LegacyReceipt(value: LegacyActionReceipt): void {
  v2Known(value, ["actionId", "originalSequence", "originalIntentHash"]);
  v2Require(shortText(value.actionId) && safeCounter(value.originalSequence) && value.originalSequence > 0 && hashValue(value.originalIntentHash));
}
export function validateV2Chunk(value: unknown, viewer: string): asserts value is V2Chunk {
  const chunk = value as V2Chunk;
  v2Require(chunk && typeof chunk === "object");
  v2Known(chunk, ["$type", "version", "kind", "previous", chunk.kind === "state" ? "fragments" : "receipts"]);
  v2Require(chunk.$type === CHUNK_COLLECTION && chunk.version === 2);
  if (chunk.previous !== undefined) reference(chunk.previous, viewer);
  const items = chunk.kind === "state" ? chunk.fragments : chunk.receipts;
  v2Require(Array.isArray(items) && items.length > 0 && items.length <= 128);
  if (chunk.kind === "state") chunk.fragments.forEach(validateV2Fragment);
  else if (chunk.kind === "devices") chunk.receipts.forEach(validateV2DeviceReceipt);
  else if (chunk.kind === "legacyReceipts") chunk.receipts.forEach(validateV2LegacyReceipt);
  else throw new ReadStateError("invalid_record");
  if (jsonBytes(chunk) > MAX_RECORD_BYTES) throw new ReadStateError("size_limit");
}
