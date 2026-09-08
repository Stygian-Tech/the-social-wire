import { CHUNK_COLLECTION, MANIFEST_COLLECTION, MAX_RECORD_BYTES, ReadStateError,
  type Chunk, type Intent, type Manifest, type Operation, type Reference } from "./types";

export const jsonBytes = (value: unknown): number => new TextEncoder().encode(JSON.stringify(value)).length;
function requireValue(condition: unknown): asserts condition {
  if (!condition) throw new ReadStateError("invalid_record");
}
const text = (value: unknown, maximum: number): value is string =>
  typeof value === "string" && value.length > 0 && new TextEncoder().encode(value).length <= maximum;
export function dateValue(value: unknown): number {
  requireValue(typeof value === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?(?:Z|[+-]\d\d:\d\d)$/.test(value));
  const date = Date.parse(value);
  requireValue(Number.isFinite(date));
  return date;
}
/** Exact sub-millisecond ordering for PostgreSQL created_at watermarks. */
export function timestampValue(value: string): bigint {
  const milliseconds = dateValue(value);
  const fraction = /\.(\d+)(?:Z|[+-]\d\d:\d\d)$/.exec(value)?.[1] ?? "";
  if (fraction.length > 9) throw new ReadStateError("invalid_record");
  return BigInt(Math.floor(milliseconds / 1000)) * BigInt(1_000_000_000)
    + BigInt(fraction.padEnd(9, "0") || "0");
}
export function validateReference(reference: Reference, viewer: string): void {
  const prefix = `at://${viewer}/${CHUNK_COLLECTION}/`;
  if (!viewer.startsWith("did:") || !reference || typeof reference.uri !== "string"
    || !reference.uri.startsWith(prefix) || !text(reference.cid, 256)) throw new ReadStateError("invalid_reference");
  const key = reference.uri.slice(prefix.length);
  if (!/^[a-zA-Z0-9._~:-]{1,512}$/.test(key) || key === "." || key === "..") throw new ReadStateError("invalid_reference");
}
export function validateIntent(intent: Intent, bounded = false): void {
  requireValue(intent && text(intent.actionId, 128) && (intent.state === "read" || intent.state === "unread"));
  dateValue(intent.actedAt);
  if (intent.calendar) {
    requireValue(intent.selection === "exact");
    dateValue(intent.calendar.cutoff);
    requireValue(text(intent.calendar.timeZone, 128) && /^\d{4}-\d\d-\d\d$/.test(intent.calendar.referenceDate));
    try { new Intl.DateTimeFormat("en", { timeZone: intent.calendar.timeZone }); }
    catch { throw new ReadStateError("invalid_record"); }
  }
  if (intent.selection === "exact") {
    requireValue(intent.boundaries === undefined && Array.isArray(intent.subjectUris)
      && intent.subjectUris.length > 0 && (!bounded || intent.subjectUris.length <= 256));
    requireValue(intent.subjectUris.every(uri => text(uri, 2048)) && new Set(intent.subjectUris).size === intent.subjectUris.length);
  } else {
    requireValue(intent.selection === "boundaries" && intent.subjectUris === undefined && Array.isArray(intent.boundaries)
      && intent.boundaries.length > 0 && (!bounded || intent.boundaries.length <= 128));
    for (const boundary of intent.boundaries) {
      requireValue(boundary?.scope && text(boundary.scope.publicationId, 2048)
        && text(boundary.scope.authorDid, 2048) && boundary.scope.authorDid.startsWith("did:")
        && Array.isArray(boundary.scope.publicationSiteKeys) && boundary.scope.publicationSiteKeys.length <= 128
        && boundary.scope.publicationSiteKeys.every(key => text(key, 2048))
        && (boundary.entryId === undefined || text(boundary.entryId, 2048)));
      dateValue(boundary.createdAt);
    }
  }
}
export function validateOperation(operation: Operation): void {
  validateIntent(operation, true);
  requireValue(Number.isSafeInteger(operation.sequence) && operation.sequence > 0);
}
export function validateManifest(value: unknown, viewer: string): asserts value is Manifest {
  const manifest = value as Manifest;
  requireValue(manifest && manifest.$type === MANIFEST_COLLECTION && manifest.version === 1
    && text(manifest.generation, 128) && Number.isSafeInteger(manifest.lastSequence) && manifest.lastSequence >= 0
    && (manifest.head !== undefined || manifest.lastSequence === 0));
  if (manifest.head) validateReference(manifest.head, viewer);
  if (jsonBytes(manifest) > MAX_RECORD_BYTES) throw new ReadStateError("size_limit");
}
export function validateChunk(value: unknown, viewer: string): asserts value is Chunk {
  const chunk = value as Chunk;
  requireValue(chunk && chunk.$type === CHUNK_COLLECTION && chunk.version === 1
    && Array.isArray(chunk.operations) && chunk.operations.length > 0 && chunk.operations.length <= 128);
  chunk.operations.forEach(validateOperation);
  if (chunk.previous) validateReference(chunk.previous, viewer);
  if (jsonBytes(chunk) > MAX_RECORD_BYTES) throw new ReadStateError("size_limit");
}
