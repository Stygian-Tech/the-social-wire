import { CHUNK_COLLECTION, MANIFEST_COLLECTION, MAX_RECORD_BYTES, ReadStateError, type Intent, type Operation, type Reference } from "./types";
import { loadGeneration, packIntent, recordCID, type LoadedGeneration, type ReadStateRepository, type RepositoryRecord } from "./repository";
import { ReadStateProjection } from "./projection";
import { jsonBytes } from "./validation";
import { compactReadState, advanceDeviceReceipt, initialDeviceReceipt, originalIntentHash, type DeviceReceipt, type LegacyActionReceipt } from "./v2Foundation";
import { fragmentOperation, validateV2Chunk, validateV2Manifest, v2Require } from "./v2Validation";
import type { V2Chunk, V2Fragment, V2Manifest, V2PublicationCheckpoint } from "./v2Types";

export type LoadedV2Generation = { record: RepositoryRecord; manifest: V2Manifest; fragments: V2Fragment[];
  devices: DeviceReceipt[]; legacyReceipts: LegacyActionReceipt[]; projection: ReadStateProjection;
  references: Reference[]; stateChunkCount: number; stateBytes: number; deviceChunkCount: number; deviceBytes: number; chunkBytes: number };
export type AllocatedV2Intent = { intent: Intent; deviceId: string; deviceCounter: number; intentHash: string };
type ChunkKind = V2Chunk["kind"];
type Item = V2Fragment | DeviceReceipt | LegacyActionReceipt;
type PlannedChunk = { reference: Reference; value: V2Chunk };
const reserve: Reference = { uri: "a".repeat(2800), cid: "c".repeat(256) };

async function verify(record: RepositoryRecord, uri: string, cid?: string) {
  if (record.uri !== uri || (cid !== undefined && record.cid !== cid)) throw new ReadStateError("invalid_reference");
  if (record.cid !== await recordCID(record.value)) throw new ReadStateError("invalid_cid");
}
export async function loadV2Generation(repository: ReadStateRepository, record?: RepositoryRecord): Promise<LoadedV2Generation> {
  record ??= await repository.getRecord(MANIFEST_COLLECTION, "self") ?? undefined;
  if (!record) throw new ReadStateError("incomplete_generation");
  await verify(record, `at://${repository.viewerDid}/${MANIFEST_COLLECTION}/self`);
  validateV2Manifest(record.value, repository.viewerDid);
  const manifest = record.value;
  const fragments: V2Fragment[] = [], devices: DeviceReceipt[] = [], legacyReceipts: LegacyActionReceipt[] = [], references: Reference[] = [];
  const visited = new Set<string>(); let chunkBytes = 0, stateBytes = 0, stateChunkCount = 0, deviceBytes = 0, deviceChunkCount = 0;
  const started = performance.now();
  for (const [kind, root] of [["state", manifest.stateHead], ["devices", manifest.devicesHead], ["legacyReceipts", manifest.legacyReceiptsHead]] as const) {
    let reference = root;
    while (reference) {
      if (visited.has(reference.uri)) throw new ReadStateError("invalid_reference");
      visited.add(reference.uri);
      if (visited.size > 4096 || performance.now() - started > 30_000) throw new ReadStateError("size_limit");
      const chunk = await repository.getRecord(CHUNK_COLLECTION, reference.uri.split("/").at(-1)!, reference.cid);
      if (!chunk) throw new ReadStateError("incomplete_generation");
      await verify(chunk, reference.uri, reference.cid); validateV2Chunk(chunk.value, repository.viewerDid);
      if (chunk.value.kind !== kind) throw new ReadStateError("invalid_record");
      const bytes = jsonBytes(chunk.value); chunkBytes += bytes;
      if (chunkBytes > 16 * 1024 * 1024 || performance.now() - started > 30_000) throw new ReadStateError("size_limit");
      references.push(reference);
      if (chunk.value.kind === "state") { fragments.push(...chunk.value.fragments); stateChunkCount++; stateBytes += bytes; }
      else if (chunk.value.kind === "devices") { devices.push(...chunk.value.receipts); deviceBytes += bytes; deviceChunkCount++; }
      else legacyReceipts.push(...chunk.value.receipts);
      reference = chunk.value.previous;
    }
  }
  const byDevice = new Map<string, DeviceReceipt>(), byLegacy = new Map<string, LegacyActionReceipt>();
  for (const [index, receipt] of devices.entries()) {
    v2Require(index === 0 || devices[index - 1].deviceId < receipt.deviceId);
    if (receipt.committedCounter === 0) v2Require(receipt.prefixHash === (await initialDeviceReceipt(repository.viewerDid, receipt.deviceId)).prefixHash);
    byDevice.set(receipt.deviceId, receipt);
  }
  for (const [index, receipt] of legacyReceipts.entries()) {
    v2Require(receipt.originalSequence <= manifest.lastSequence && !byLegacy.has(receipt.actionId)
      && (index === 0 || legacyReceipts[index - 1].originalSequence < receipt.originalSequence));
    byLegacy.set(receipt.actionId, receipt);
  }
  const identities = new Map<string, string>(), counters = new Map<string, string>();
  for (const fragment of fragments) {
    const identity = JSON.stringify([fragment.sequence, fragment.intentHash, fragment.deviceId, fragment.deviceCounter,
      fragment.state, fragment.actedAt, fragment.selection, fragment.calendar ?? null]);
    if (identities.has(fragment.actionId) && identities.get(fragment.actionId) !== identity) throw new ReadStateError("conflicting_sequence");
    identities.set(fragment.actionId, identity);
    if (fragment.deviceId !== undefined) {
      const receipt = byDevice.get(fragment.deviceId), key = `${fragment.deviceId}:${fragment.deviceCounter}`;
      v2Require(receipt && fragment.deviceCounter! <= receipt.committedCounter
        && fragment.sequence > (legacyReceipts.at(-1)?.originalSequence ?? 0));
      if (counters.has(key) && counters.get(key) !== fragment.actionId) throw new ReadStateError("conflicting_sequence");
      counters.set(key, fragment.actionId);
    } else {
      const receipt = byLegacy.get(fragment.actionId);
      v2Require(receipt && receipt.originalIntentHash === fragment.intentHash && receipt.originalSequence === fragment.sequence);
    }
  }
  return { record, manifest, fragments, devices, legacyReceipts, references, stateChunkCount, stateBytes, deviceChunkCount, deviceBytes, chunkBytes,
    projection: new ReadStateProjection(fragments.map(fragmentOperation), manifest.lastSequence, true) };
}

/** Reuse the reviewed semantic selector without deriving new receipts from partial fragments. */
export async function compactV2Fragments(fragments: V2Fragment[], viewer: string): Promise<V2Fragment[]> {
  if (!fragments.length) return [];
  const operations = fragments.map(fragmentOperation), maximum = operations.reduce((maximum, op) => Math.max(maximum, op.sequence), 0);
  const view: LoadedGeneration = { record: null, manifest: { $type: MANIFEST_COLLECTION, version: 1,
    generation: "semantic-selector-view", lastSequence: maximum, head: { uri: `at://${viewer}/${CHUNK_COLLECTION}/selector`, cid: "selector" } },
    projection: new ReadStateProjection(operations, maximum), chunkCount: 0, chunkBytes: 0, repackAllowed: true };
  const compacted = await compactReadState(view, viewer);
  const identities = new Map(fragments.map(fragment => [fragment.actionId, fragment]));
  return compacted.operations.map(operation => {
    const identity = identities.get(operation.actionId)!;
    return { ...operation, fragment: true, intentHash: identity.intentHash,
      ...(identity.deviceId === undefined ? {} : { deviceId: identity.deviceId, deviceCounter: identity.deviceCounter }) };
  });
}
function chunkValue(kind: ChunkKind, items: Item[], previous?: Reference): V2Chunk {
  return { $type: CHUNK_COLLECTION, version: 2, kind, ...(previous ? { previous } : {}),
    ...(kind === "state" ? { fragments: items as V2Fragment[] } : { receipts: items }) } as V2Chunk;
}
async function planPages(repository: ReadStateRepository, kind: ChunkKind, items: Item[], previous?: Reference): Promise<{ head?: Reference; chunks: PlannedChunk[] }> {
  const bounded: Item[] = [];
  function split(item: Item) {
    if (kind !== "state" || jsonBytes(chunkValue(kind, [item], reserve)) <= MAX_RECORD_BYTES) { bounded.push(item); return; }
    const fragment = item as V2Fragment, values = fragment.selection === "exact" ? fragment.subjectUris : fragment.boundaries;
    if (values.length === 1) throw new ReadStateError("size_limit");
    const middle = Math.ceil(values.length / 2);
    for (const half of [values.slice(0, middle), values.slice(middle)]) split({ ...fragment,
      ...(fragment.selection === "exact" ? { subjectUris: half } : { boundaries: half }) } as V2Fragment);
  }
  items.forEach(split);
  const groups: Item[][] = [];
  for (const item of bounded) {
    let group = groups.at(-1);
    if (!group || group.length === 128 || jsonBytes(chunkValue(kind, [...group, item], reserve)) > MAX_RECORD_BYTES) { group = []; groups.push(group); }
    group.push(item);
    if (jsonBytes(chunkValue(kind, group, reserve)) > MAX_RECORD_BYTES) throw new ReadStateError("size_limit");
  }
  let head = previous; const chunks: PlannedChunk[] = [];
  // Reverse upload order gives deterministic forward order while traversing receipt pages.
  for (const group of groups.reverse()) {
    const value = chunkValue(kind, group, head); validateV2Chunk(value, repository.viewerDid);
    const cid = await recordCID(value), reference = { uri: `at://${repository.viewerDid}/${CHUNK_COLLECTION}/${cid}`, cid };
    chunks.push({ reference, value }); head = reference;
  }
  return { head, chunks };
}
async function publishPlan(repository: ReadStateRepository, manifest: V2Manifest, baseCid: string,
  chunks: PlannedChunk[], existingCount: number, existingBytes: number,
  checkpoint?: (value: V2PublicationCheckpoint) => Promise<void>): Promise<Reference> {
  validateV2Manifest(manifest, repository.viewerDid);
  if (existingCount + chunks.length > 4096 || existingBytes + chunks.reduce((sum, chunk) => sum + jsonBytes(chunk.value), 0) > 16 * 1024 * 1024)
    throw new ReadStateError("size_limit");
  const progress: V2PublicationCheckpoint = { baseCid, revision: manifest.revision, uploaded: [] };
  await checkpoint?.(structuredClone(progress));
  for (const chunk of chunks) {
    // Re-upload on EVERY candidate, including after a maintenance-only CID change.
    // Never trust an old uploaded checkpoint after another writer/GC changes the base.
    let reference: Reference;
    try { reference = await repository.putRecord(CHUNK_COLLECTION, chunk.reference.cid, chunk.value, null); }
    catch (error) {
      if (!(error instanceof ReadStateError && error.code === "conflict")) throw error;
      const existing = await repository.getRecord(CHUNK_COLLECTION, chunk.reference.cid, chunk.reference.cid);
      if (!existing) throw new ReadStateError("incomplete_generation");
      await verify(existing, chunk.reference.uri, chunk.reference.cid); reference = existing;
    }
    if (reference.uri !== chunk.reference.uri || reference.cid !== chunk.reference.cid) throw new ReadStateError("invalid_cid");
    progress.uploaded.push(chunk.reference); await checkpoint?.(structuredClone(progress));
  }
  const reference = await repository.putRecord(MANIFEST_COLLECTION, "self", manifest, baseCid);
  await verify({ ...reference, value: manifest }, `at://${repository.viewerDid}/${MANIFEST_COLLECTION}/self`);
  return reference;
}
export async function ensureV2Generation(repository: ReadStateRepository, confirm: (reference: Reference) => Promise<void>): Promise<LoadedV2Generation> {
  for (let attempt = 0; attempt < 4; attempt++) {
    const current = await repository.getRecord(MANIFEST_COLLECTION, "self");
    if (!current) throw new ReadStateError("incomplete_generation");
    if ((current.value as { version?: number }).version === 2) return loadV2Generation(repository, current);
    const generation = await loadGeneration(repository);
    if (!generation.record) throw new ReadStateError("incomplete_generation");
    // The unpruned v1 baseline must first pass existing AppView parity and authority checks.
    await confirm(generation.record);
    const compacted = await compactReadState(generation, repository.viewerDid);
    const receipts = new Map(compacted.receipts.map(receipt => [receipt.actionId, receipt]));
    const fragments: V2Fragment[] = compacted.operations.map(operation => ({ ...operation, fragment: true,
      intentHash: receipts.get(operation.actionId)!.originalIntentHash }));
    const state = await planPages(repository, "state", fragments), legacy = await planPages(repository, "legacyReceipts", compacted.receipts);
    const manifest: V2Manifest = { $type: MANIFEST_COLLECTION, version: 2, generation: crypto.randomUUID(), revision: generation.manifest.lastSequence + 1,
      compactionVersion: 1, lastSequence: generation.manifest.lastSequence,
      ...(state.head ? { stateHead: state.head } : {}), ...(legacy.head ? { legacyReceiptsHead: legacy.head } : {}) };
    try {
      const reference = await publishPlan(repository, manifest, generation.record.cid, [...state.chunks, ...legacy.chunks], 0, 0);
      await confirm(reference);
      return loadV2Generation(repository);
    } catch (error) { if (!(error instanceof ReadStateError && error.code === "conflict")) throw error; }
  }
  throw new ReadStateError("conflict");
}
export async function publishV2Intents(repository: ReadStateRepository, generation: LoadedV2Generation,
  intents: AllocatedV2Intent[], receipt: DeviceReceipt, checkpoint?: (value: V2PublicationCheckpoint) => Promise<void>): Promise<Reference> {
  if (!intents.length) throw new ReadStateError("invalid_record");
  const currentReceipt = generation.devices.find(value => value.deviceId === receipt.deviceId)
    ?? await initialDeviceReceipt(repository.viewerDid, receipt.deviceId);
  if (currentReceipt.committedCounter !== receipt.committedCounter || currentReceipt.prefixHash !== receipt.prefixHash)
    throw new ReadStateError("conflicting_sequence");
  const newFragments: V2Fragment[] = [];
  let lastSequence = generation.manifest.lastSequence;
  for (const [index, value] of intents.entries()) {
    v2Require(value.deviceId === receipt.deviceId && value.deviceCounter === receipt.committedCounter + index + 1
      && await originalIntentHash(packIntent(value.intent, 1).flat()) === value.intentHash);
    const legacy = generation.legacyReceipts.find(item => item.actionId === value.intent.actionId);
    if (legacy) {
      if (legacy.originalIntentHash !== value.intentHash) throw new ReadStateError("conflicting_sequence");
      continue; // An old random-ID retry needs only a device receipt, never a second semantic action.
    }
    if (generation.fragments.some(item => item.actionId === value.intent.actionId)) throw new ReadStateError("conflicting_sequence");
    lastSequence++;
    newFragments.push(...packIntent(value.intent, lastSequence).flat().map(operation => ({ ...operation,
      fragment: true as const, deviceId: value.deviceId, deviceCounter: value.deviceCounter, intentHash: value.intentHash })));
  }
  const nextReceipt = await advanceDeviceReceipt(receipt, intents[0].deviceCounter, intents.map(value => value.intentHash));
  const devices = generation.devices.filter(value => value.deviceId !== receipt.deviceId).concat(nextReceipt).sort((a, b) => a.deviceId < b.deviceId ? -1 : 1);
  const append = await planPages(repository, "state", newFragments, generation.manifest.stateHead);
  // Match native's bounded cadence; ordinary taps do not repeatedly hash and compact every old action.
  const compact = generation.stateChunkCount + append.chunks.length >= 64 || generation.chunkBytes > 12 * 1024 * 1024;
  const state = compact
    ? await planPages(repository, "state", await compactV2Fragments([...generation.fragments, ...newFragments], repository.viewerDid))
    : append;
  const devicePages = await planPages(repository, "devices", devices);
  const existingCount = generation.references.length - generation.deviceChunkCount - (compact ? generation.stateChunkCount : 0);
  const existingBytes = generation.chunkBytes - generation.deviceBytes - (compact ? generation.stateBytes : 0);
  const manifest: V2Manifest = { ...generation.manifest, generation: crypto.randomUUID(), revision: generation.manifest.revision + 1,
    lastSequence, stateHead: state.head, devicesHead: devicePages.head };
  return publishPlan(repository, manifest, generation.record.cid, [...state.chunks, ...devicePages.chunks], existingCount, existingBytes, checkpoint);
}
export async function compactV2Generation(repository: ReadStateRepository, confirm: (reference: Reference) => Promise<void>): Promise<Reference> {
  for (let attempt = 0; attempt < 4; attempt++) {
    const generation = await ensureV2Generation(repository, confirm); await confirm(generation.record);
    const state = await planPages(repository, "state", await compactV2Fragments(generation.fragments, repository.viewerDid));
    const { stateHead: _old, ...base } = generation.manifest;
    const manifest: V2Manifest = { ...base, generation: crypto.randomUUID(), revision: base.revision + 1,
      ...(state.head ? { stateHead: state.head } : {}) };
    try {
      const reference = await publishPlan(repository, manifest, generation.record.cid, state.chunks,
        generation.references.length - generation.stateChunkCount, generation.chunkBytes - generation.stateBytes);
      await confirm(reference); return reference;
    } catch (error) { if (!(error instanceof ReadStateError && error.code === "conflict")) throw error; }
  }
  throw new ReadStateError("conflict");
}
