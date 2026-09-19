import { encode } from "@atproto/lex-cbor";
import type { LoadedGeneration } from "./repository";
import { ReadStateProjection } from "./projection";
import { ReadStateError, type Boundary, type Operation } from "./types";
import { timestampValue, validateOperation, validateManifest } from "./validation";

export type LegacyActionReceipt = { actionId: string; originalSequence: number; originalIntentHash: string };
export type DeviceReceipt = { deviceId: string; committedCounter: number; prefixHash: string };
const utf8 = (s: string) => new TextEncoder().encode(s);
const compare = (a: string, b: string): number => {
  const x = utf8(a), y = utf8(b);
  for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] - y[i];
  return x.length - y.length;
};
const sortedSet = (values: readonly string[]) => [...new Set(values)].sort(compare);
function known(value: object, keys: string[]): void {
  if (Object.keys(value).some(key => !keys.includes(key))) throw new ReadStateError("invalid_record", "Unknown compaction semantics");
}
function checkOperation(op: Operation): void {
  validateOperation(op);
  known(op, ["actionId", "sequence", "state", "actedAt", "selection", "subjectUris", "boundaries", "calendar"]);
  if (op.calendar) known(op.calendar, ["cutoff", "timeZone", "referenceDate"]);
  for (const b of op.boundaries ?? []) {
    known(b, ["scope", "createdAt", "entryId"]);
    known(b.scope, ["publicationId", "authorDid", "publicationSiteKeys"]);
  }
}
function canonicalBoundary(b: Boundary): Boundary {
  return { scope: { publicationId: b.scope.publicationId, authorDid: b.scope.authorDid,
    publicationSiteKeys: sortedSet(b.scope.publicationSiteKeys) }, createdAt: b.createdAt,
    ...(b.entryId === undefined ? {} : { entryId: b.entryId }) };
}
function hex(bytes: Uint8Array): string { return [...bytes].map(v => v.toString(16).padStart(2, "0")).join(""); }
function canonicalKey(value: unknown): string { return hex(encode(value as Parameters<typeof encode>[0])); }
async function digest(value: unknown): Promise<string> {
  const bytes = encode(value as Parameters<typeof encode>[0]);
  if (bytes.byteLength > 16 * 1024 * 1024) throw new ReadStateError("size_limit");
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes))));
}
/** Hash the entire original action, assembled across chunks, never a compacted fragment. */
export async function originalIntentHash(parts: readonly Operation[]): Promise<string> {
  const first = parts[0];
  if (!first) throw new ReadStateError("invalid_record");
  for (const part of parts) {
    checkOperation(part);
    if (part.actionId !== first.actionId || part.sequence !== first.sequence || part.state !== first.state
      || part.actedAt !== first.actedAt || part.selection !== first.selection
      || canonicalKey(part.calendar ?? null) !== canonicalKey(first.calendar ?? null)) throw new ReadStateError("conflicting_sequence");
  }
  const base = { actionId: first.actionId, state: first.state, actedAt: first.actedAt, selection: first.selection,
    ...(first.calendar ? { calendar: first.calendar } : {}) };
  const selection = first.selection === "exact"
    ? { subjectUris: sortedSet(parts.flatMap(p => p.subjectUris ?? [])) }
    : { boundaries: [...new Map(parts.flatMap(p => p.boundaries ?? []).map(canonicalBoundary)
      .map(b => [canonicalKey(b), b])).values()].sort((a, b) => compare(canonicalKey(a), canonicalKey(b))) };
  return digest(["app.thesocialwire.read-state/original-intent/v2", { ...base, ...selection }]);
}
function validateReceipt(receipt: DeviceReceipt): void {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(receipt.deviceId)
    || !Number.isSafeInteger(receipt.committedCounter) || receipt.committedCounter < 0
    || !/^[0-9a-f]{64}$/.test(receipt.prefixHash)) throw new ReadStateError("invalid_record");
}
export async function initialDeviceReceipt(viewerDid: string, deviceId: string): Promise<DeviceReceipt> {
  if (!viewerDid.startsWith("did:") || utf8(viewerDid).length > 2048) throw new ReadStateError("invalid_record");
  const result = { deviceId, committedCounter: 0,
    prefixHash: await digest(["app.thesocialwire.read-state/device/v2", viewerDid, deviceId]) };
  validateReceipt(result); return result;
}
export async function advanceDeviceReceipt(receipt: DeviceReceipt, firstCounter: number,
  hashes: readonly string[]): Promise<DeviceReceipt> {
  validateReceipt(receipt);
  if (!hashes.length || firstCounter !== receipt.committedCounter + 1
    || !Number.isSafeInteger(receipt.committedCounter + hashes.length)) throw new ReadStateError("conflicting_sequence");
  let prefixHash = receipt.prefixHash;
  for (let index = 0; index < hashes.length; index++) {
    if (!/^[0-9a-f]{64}$/.test(hashes[index])) throw new ReadStateError("invalid_record");
    prefixHash = await digest(["app.thesocialwire.read-state/prefix/v2", prefixHash, firstCounter + index, hashes[index]]);
  }
  return { ...receipt, prefixHash, committedCounter: receipt.committedCounter + hashes.length };
}
/** Returns the verified pending prefix length; mismatch never authorizes dropping queue items. */
export async function verifyDeviceAcknowledgement(local: DeviceReceipt, remote: DeviceReceipt,
  pendingHashes: readonly string[]): Promise<number> {
  validateReceipt(local); validateReceipt(remote);
  const count = remote.committedCounter - local.committedCounter;
  if (local.deviceId !== remote.deviceId || count < 0 || count > pendingHashes.length) throw new ReadStateError("conflicting_sequence");
  const expected = count ? await advanceDeviceReceipt(local, local.committedCounter + 1, pendingHashes.slice(0, count)) : local;
  if (expected.prefixHash !== remote.prefixHash) throw new ReadStateError("conflicting_sequence");
  return count;
}
function boundCompare(a: Boundary, b: Boundary): number {
  const at = timestampValue(a.createdAt), bt = timestampValue(b.createdAt);
  if (at !== bt) return at < bt ? -1 : 1;
  if (a.entryId === undefined) return b.entryId === undefined ? 0 : 1;
  return b.entryId === undefined ? -1 : compare(a.entryId, b.entryId);
}
/** Pure foundation only. Caller supplies a complete CID-verified generation. No writes or GC. */
export async function compactReadState(generation: LoadedGeneration, viewerDid: string): Promise<{ operations: Operation[]; receipts: LegacyActionReceipt[] }> {
  validateManifest(generation.manifest, viewerDid);
  if (!generation.repackAllowed) throw new ReadStateError("invalid_record", "Unknown compaction semantics");
  known(generation.manifest, ["$type", "version", "generation", "lastSequence", "head"]);
  if (generation.manifest.head) known(generation.manifest.head, ["uri", "cid"]);
  new ReadStateProjection(generation.projection.operations, generation.manifest.lastSequence);
  const actions = new Map<string, Operation[]>();
  for (const op of generation.projection.operations) {
    checkOperation(op);
    for (const b of op.boundaries ?? []) {
      const fraction = /\.(\d+)(?:Z|[+-]\d\d:\d\d)$/.exec(b.createdAt)?.[1] ?? "";
      if (/[1-9]/.test(fraction.slice(6))) throw new ReadStateError("invalid_record", "Unsupported compaction precision");
    }
    const group = actions.get(op.actionId) ?? []; group.push(op); actions.set(op.actionId, group);
  }
  const receipts: LegacyActionReceipt[] = [];
  const exact = new Map<string, Operation>();
  const rules: { op: Operation; boundary: Boundary; scope: string }[] = [];
  for (const parts of actions.values()) {
    const op = parts[0];
    receipts.push({ actionId: op.actionId, originalSequence: op.sequence, originalIntentHash: await originalIntentHash(parts) });
    for (const part of parts) {
      for (const uri of part.subjectUris ?? []) if ((exact.get(uri)?.sequence ?? 0) < op.sequence) exact.set(uri, op);
      for (const source of part.boundaries ?? []) {
        const boundary = canonicalBoundary(source);
        rules.push({ op, boundary, scope: canonicalKey(boundary.scope) });
      }
    }
  }
  const selections = new Map<string, { op: Operation; subjects: string[]; boundaries: Boundary[] }>();
  function selected(op: Operation) {
    let value = selections.get(op.actionId);
    if (!value) { value = { op, subjects: [], boundaries: [] }; selections.set(op.actionId, value); }
    return value;
  }
  for (const [uri, op] of exact) selected(op).subjects.push(uri);
  rules.sort((a, b) => b.op.sequence - a.op.sequence || compare(canonicalKey(a.boundary), canonicalKey(b.boundary)));
  const maxima = new Map<string, Boundary>();
  const seen = new Set<string>();
  for (let start = 0; start < rules.length;) {
    let end = start + 1;
    while (end < rules.length && rules[end].op.sequence === rules[start].op.sequence) end++;
    for (const rule of rules.slice(start, end)) {
      const maximum = maxima.get(rule.scope), key = `${rule.op.sequence}:${canonicalKey(rule.boundary)}`;
      if ((!maximum || boundCompare(maximum, rule.boundary) < 0) && !seen.has(key)) {
        selected(rule.op).boundaries.push(rule.boundary); seen.add(key);
      }
    }
    for (const rule of rules.slice(start, end)) {
      const maximum = maxima.get(rule.scope);
      if (!maximum || boundCompare(maximum, rule.boundary) < 0) maxima.set(rule.scope, rule.boundary);
    }
    start = end;
  }
  const operations: Operation[] = [];
  for (const { op, subjects, boundaries } of [...selections.values()].sort((a, b) => a.op.sequence - b.op.sequence)) {
    const values = op.selection === "exact" ? subjects.sort(compare) : boundaries.sort((a, b) => compare(canonicalKey(a), canonicalKey(b)));
    const maximum = op.selection === "exact" ? 256 : 128;
    for (let i = 0; i < values.length; i += maximum) {
      if (op.selection === "exact") operations.push({ ...op, subjectUris: values.slice(i, i + maximum) as string[] });
      else operations.push({ ...op, boundaries: values.slice(i, i + maximum) as Boundary[] });
    }
  }
  receipts.sort((a, b) => a.originalSequence - b.originalSequence);
  return { operations, receipts };
}
