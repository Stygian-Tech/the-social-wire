import { ReadStateError, type Boundary, type Operation, type Resolution, type Subject } from "./types";
import { timestampValue, validateOperation } from "./validation";

// PostgreSQL and Swift compare UTF-8 bytes, not browser locale collation.
function compareUTF8(left: string, right: string): number {
  const encoder = new TextEncoder(); const a = encoder.encode(left); const b = encoder.encode(right);
  for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] - b[i];
  return a.length - b.length;
}
export class ReadStateProjection {
  readonly actionIds = new Set<string>();
  private exact = new Map<string, Operation>();
  private scoped = new Map<string, { boundary: Boundary; timestamp: bigint; operation: Operation }[]>();
  constructor(readonly operations: readonly Operation[], readonly lastSequence: number, allowSparseHistory = false) {
    if (!Number.isSafeInteger(lastSequence) || lastSequence < 0) throw new ReadStateError("invalid_record");
    const sequences = new Map<number, Operation>(); const actions = new Map<string, number>();
    let maximum = 0;
    for (const operation of operations) {
      validateOperation(operation);
      if (operation.sequence > lastSequence) throw new ReadStateError("invalid_record");
      const previous = sequences.get(operation.sequence);
      if ((previous && (previous.actionId !== operation.actionId || previous.state !== operation.state
        || previous.actedAt !== operation.actedAt || JSON.stringify(previous.calendar) !== JSON.stringify(operation.calendar)))
        || (actions.has(operation.actionId) && actions.get(operation.actionId) !== operation.sequence))
        throw new ReadStateError("conflicting_sequence");
      sequences.set(operation.sequence, operation); actions.set(operation.actionId, operation.sequence);
      this.actionIds.add(operation.actionId); maximum = Math.max(maximum, operation.sequence);
      for (const uri of operation.subjectUris ?? []) if ((this.exact.get(uri)?.sequence ?? 0) < operation.sequence) this.exact.set(uri, operation);
      for (const boundary of operation.boundaries ?? []) {
        const group = this.scoped.get(boundary.scope.authorDid) ?? [];
        group.push({ boundary, timestamp: timestampValue(boundary.createdAt), operation });
        this.scoped.set(boundary.scope.authorDid, group);
      }
    }
    if (!allowSparseHistory && maximum !== lastSequence) throw new ReadStateError("incomplete_generation");
  }
  resolve(subject: Subject): Resolution {
    let latest = this.exact.get(subject.uri);
    const timestamp = timestampValue(subject.createdAt);
    for (const { boundary, timestamp: cutoff, operation } of this.scoped.get(subject.authorDid) ?? []) {
      if (operation.sequence <= (latest?.sequence ?? 0)) continue;
      const keys = boundary.scope.publicationSiteKeys;
      if (keys.length && (!subject.publicationSite || !keys.includes(subject.publicationSite))) continue;
      if (timestamp < cutoff || (timestamp === cutoff && (boundary.entryId === undefined || compareUTF8(subject.uri, boundary.entryId) <= 0))) latest = operation;
    }
    return { isRead: latest?.state === "read", sequence: latest?.sequence ?? 0,
      ...(latest ? { actionId: latest.actionId, ...(latest.state === "read" ? { readAt: latest.actedAt } : {}) } : {}) };
  }
}
