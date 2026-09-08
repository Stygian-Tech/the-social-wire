import { cidForLex, type LexValue } from "@atproto/lex-cbor";
import { CHUNK_COLLECTION, MANIFEST_COLLECTION, MAX_RECORD_BYTES, ReadStateError,
  type Chunk, type Intent, type Manifest, type Operation, type Reference } from "./types";
import { jsonBytes, validateChunk, validateIntent, validateManifest, validateReference } from "./validation";
import { ReadStateProjection } from "./projection";

export type RepositoryRecord = Reference & { value: unknown };
export interface ReadStateRepository {
  readonly viewerDid: string;
  getRecord(collection: string, rkey: string, cid?: string): Promise<RepositoryRecord | null>;
  putRecord(collection: string, rkey: string, value: Chunk | Manifest, swapRecord: string | null): Promise<Reference>;
}
export type LoadedGeneration = { record: RepositoryRecord | null; manifest: Manifest; projection: ReadStateProjection; chunkCount: number; chunkBytes: number; repackAllowed: boolean };
export async function recordCID(record: unknown): Promise<string> {
  return (await cidForLex(record as LexValue)).toString();
}
async function verifyRecord(record: RepositoryRecord, uri: string, cid?: string): Promise<void> {
  if (record.uri !== uri || (cid !== undefined && record.cid !== cid)) throw new ReadStateError("invalid_reference");
  if (await recordCID(record.value) !== record.cid) throw new ReadStateError("invalid_cid");
}
export async function loadGeneration(repository: ReadStateRepository): Promise<LoadedGeneration> {
  const record = await repository.getRecord(MANIFEST_COLLECTION, "self");
  if (!record) {
    const manifest: Manifest = { $type: MANIFEST_COLLECTION, version: 1, generation: "empty", lastSequence: 0 };
    return { record, manifest, projection: new ReadStateProjection([], 0), chunkCount: 0, chunkBytes: 0, repackAllowed: true };
  }
  await verifyRecord(record, `at://${repository.viewerDid}/${MANIFEST_COLLECTION}/self`);
  validateManifest(record.value, repository.viewerDid);
  const manifest = record.value;
  let reference = manifest.head;
  let bytes = 0; let repackAllowed = true;
  const visited = new Set<string>(); const operations: Operation[] = [];
  while (reference) {
    validateReference(reference, repository.viewerDid);
    const key = `${reference.uri}#${reference.cid}`;
    if (visited.has(key)) throw new ReadStateError("invalid_reference");
    visited.add(key);
    if (visited.size > 4096) throw new ReadStateError("size_limit");
    const chunk = await repository.getRecord(CHUNK_COLLECTION, reference.uri.split("/").at(-1)!, reference.cid);
    if (!chunk) throw new ReadStateError("incomplete_generation");
    await verifyRecord(chunk, reference.uri, reference.cid);
    validateChunk(chunk.value, repository.viewerDid);
    bytes += jsonBytes(chunk.value);
    if (bytes > 16 * 1024 * 1024) throw new ReadStateError("size_limit");
    if (Object.keys(chunk.value).some(key => !["$type", "version", "operations", "previous"].includes(key))) repackAllowed = false;
    operations.push(...chunk.value.operations);
    reference = chunk.value.previous;
  }
  return { record, manifest, projection: new ReadStateProjection(operations, manifest.lastSequence), chunkCount: visited.size, chunkBytes: bytes, repackAllowed };
}

// Reserve room for the longest allowed previous strong reference before packing.
const referenceReserve: Reference = { uri: "a".repeat(2800), cid: "c".repeat(256) };
export function packIntent(intent: Intent, sequence: number): Operation[][] {
  validateIntent(intent);
  if (!Number.isSafeInteger(sequence) || sequence < 1) throw new ReadStateError("size_limit");
  const parts: Operation[] = [];
  const values = intent.selection === "exact" ? intent.subjectUris : intent.boundaries;
  const maximum = intent.selection === "exact" ? 256 : 128;
  let index = 0;
  while (index < values.length) {
    let count = Math.min(maximum, values.length - index);
    let part: Operation;
    while (true) {
      part = { ...intent, sequence, ...(intent.selection === "exact"
        ? { subjectUris: intent.subjectUris.slice(index, index + count) }
        : { boundaries: intent.boundaries.slice(index, index + count) }) } as Operation;
      if (jsonBytes({ $type: CHUNK_COLLECTION, version: 1, previous: referenceReserve, operations: [part] }) <= MAX_RECORD_BYTES) break;
      if (count === 1) throw new ReadStateError("size_limit");
      count = Math.max(1, Math.floor(count / 2));
    }
    parts.push(part); index += count;
  }
  const chunks: Operation[][] = [];
  for (const part of parts) {
    const previous = chunks.at(-1);
    if (previous && previous.length < 128 && jsonBytes({ $type: CHUNK_COLLECTION, version: 1,
      previous: referenceReserve, operations: [...previous, part] }) <= MAX_RECORD_BYTES) previous.push(part);
    else chunks.push([part]);
  }
  return chunks;
}

/** Bound the complete candidate before uploading any of its chunks. */
async function preflightGroups(repository: ReadStateRepository, groups: Operation[][],
  head?: Reference, existingCount = 0, existingBytes = 0): Promise<void> {
  if (existingCount + groups.length > 4096) throw new ReadStateError("size_limit");
  let bytes = existingBytes;
  for (const operations of groups) {
    const chunk: Chunk = { $type: CHUNK_COLLECTION, version: 1, operations, ...(head ? { previous: head } : {}) };
    validateChunk(chunk, repository.viewerDid);
    bytes += jsonBytes(chunk);
    if (bytes > 16 * 1024 * 1024) throw new ReadStateError("size_limit");
    const cid = await recordCID(chunk);
    head = { uri: `at://${repository.viewerDid}/${CHUNK_COLLECTION}/${cid}`, cid };
  }
}

async function uploadGroups(repository: ReadStateRepository, groups: Operation[][], head?: Reference,
  beforeWrite?: () => Promise<void>): Promise<Reference | undefined> {
  for (const operations of groups) {
    const chunk: Chunk = { $type: CHUNK_COLLECTION, version: 1, operations, ...(head ? { previous: head } : {}) };
    validateChunk(chunk, repository.viewerDid);
    const cid = await recordCID(chunk);
    await beforeWrite?.();
    try {
      head = await repository.putRecord(CHUNK_COLLECTION, cid, chunk, null);
    } catch (error) {
      if (!(error instanceof ReadStateError && error.code === "conflict")) throw error;
      const existing = await repository.getRecord(CHUNK_COLLECTION, cid, cid);
      if (!existing) throw new ReadStateError("incomplete_generation");
      await verifyRecord(existing, `at://${repository.viewerDid}/${CHUNK_COLLECTION}/${cid}`, cid);
      head = { uri: existing.uri, cid: existing.cid };
    }
    if (head.cid !== cid) throw new ReadStateError("invalid_cid");
    validateReference(head, repository.viewerDid);
  }
  return head;
}
export function packOperations(operations: Operation[]): Operation[][] {
  const groups: Operation[][] = [];
  for (const operation of operations) {
    const group = groups.at(-1);
    if (group && group.length < 128 && jsonBytes({ $type: CHUNK_COLLECTION, version: 1,
      previous: referenceReserve, operations: [...group, operation] }) <= MAX_RECORD_BYTES) group.push(operation);
    else groups.push([operation]);
  }
  return groups;
}
async function publish(repository: ReadStateRepository, manifest: Manifest, previousCid: string | null): Promise<Reference> {
  const committed = await repository.putRecord(MANIFEST_COLLECTION, "self", manifest, previousCid);
  if (committed.uri !== `at://${repository.viewerDid}/${MANIFEST_COLLECTION}/self`
    || committed.cid !== await recordCID(manifest)) throw new ReadStateError("invalid_cid");
  return committed;
}
function matchingIntent(projection: ReadStateProjection, intent: Intent): boolean {
  const parts = projection.operations.filter(operation => operation.actionId === intent.actionId);
  if (!parts.length) return false;
  if (parts.some(operation => operation.state !== intent.state || operation.actedAt !== intent.actedAt
    || operation.selection !== intent.selection || JSON.stringify(operation.calendar) !== JSON.stringify(intent.calendar)))
    throw new ReadStateError("conflicting_sequence");
  const selected = intent.selection === "exact" ? parts.flatMap(part => part.subjectUris ?? [])
    : parts.flatMap(part => (part.boundaries ?? []).map(boundary => JSON.stringify(boundary)));
  const expected = intent.selection === "exact" ? intent.subjectUris : intent.boundaries.map(boundary => JSON.stringify(boundary));
  if (JSON.stringify([...new Set(selected)].sort()) !== JSON.stringify([...new Set(expected)].sort()))
    throw new ReadStateError("conflicting_sequence");
  return true;
}
export async function commitIntents(repository: ReadStateRepository, intents: Intent[],
  options: { maximumConflicts?: number; beforeWrite?: () => Promise<void>; requireExistingManifest?: boolean } = {}): Promise<Reference> {
  if (!intents.length || new Set(intents.map(intent => intent.actionId)).size !== intents.length)
    throw new ReadStateError("invalid_record");
  intents.forEach(intent => validateIntent(intent));
  for (let attempt = 0; attempt <= (options.maximumConflicts ?? 3); attempt++) {
    const generation = await loadGeneration(repository);
    if (options.requireExistingManifest && !generation.record) throw new ReadStateError("incomplete_generation");
    const missing = intents.filter(intent => !matchingIntent(generation.projection, intent));
    if (!missing.length) return generation.record!;
    const operations = missing.flatMap((intent, index) => packIntent(intent, generation.manifest.lastSequence + index + 1).flat());
    const appendedGroups = packOperations(operations);
    const denseGroups = packOperations([...generation.projection.operations, ...operations]);
    // Repack fragmented chains without pruning action IDs needed for unknown-success retries.
    const repack = generation.repackAllowed && generation.chunkCount + appendedGroups.length > denseGroups.length + 64;
    const groups = repack ? denseGroups : appendedGroups;
    const previous = repack ? undefined : generation.manifest.head;
    await preflightGroups(repository, groups, previous, repack ? 0 : generation.chunkCount, repack ? 0 : generation.chunkBytes);
    const head = await uploadGroups(repository, groups, previous, options.beforeWrite);
    const manifest: Manifest = { ...generation.manifest, $type: MANIFEST_COLLECTION, version: 1, generation: crypto.randomUUID(),
      lastSequence: generation.manifest.lastSequence + missing.length, ...(head ? { head } : {}) };
    await options.beforeWrite?.();
    try { return await publish(repository, manifest, generation.record?.cid ?? null); }
    catch (error) { if (!(error instanceof ReadStateError && error.code === "conflict")) throw error; }
  }
  throw new ReadStateError("conflict", "Read state changed on another device; retry after refreshing.");
}
export async function commitIntent(repository: ReadStateRepository, intent: Intent,
  options: { maximumConflicts?: number; beforeWrite?: () => Promise<void>; requireExistingManifest?: boolean } = {}): Promise<Reference> {
  return commitIntents(repository, [intent], options);
}
/** Initial migration only: the server revision fence and parity check authorize activation. */
export async function publishMigration(repository: ReadStateRepository, generationId: string,
  intents: Intent[], expectedManifestCid: string | null): Promise<Reference> {
  const operations = intents.flatMap((intent, index) => packIntent(intent, index + 1).flat());
  new ReadStateProjection(operations, intents.length);
  const groups = packOperations(operations);
  await preflightGroups(repository, groups);
  const head = await uploadGroups(repository, groups);
  const manifest: Manifest = { $type: MANIFEST_COLLECTION, version: 1, generation: generationId,
    lastSequence: intents.length, ...(head ? { head } : {}) };
  validateManifest(manifest, repository.viewerDid);
  // Handles a successful previous CAS whose response never reached the outbox.
  const current = await repository.getRecord(MANIFEST_COLLECTION, "self");
  if (current && current.cid === await recordCID(manifest)) {
    await verifyRecord(current, `at://${repository.viewerDid}/${MANIFEST_COLLECTION}/self`);
    return current;
  }
  return publish(repository, manifest, expectedManifestCid);
}
