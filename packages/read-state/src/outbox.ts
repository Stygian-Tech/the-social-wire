import type { V2DeviceState, V2PublicationCheckpoint } from "./v2Types";
import { commitIntents, type ReadStateRepository } from "./repository";
import { ReadStateError, type Intent, type Reference } from "./types";
import { validateIntent } from "./validation";

export type OutboxEntry = { intent: Intent; attempts: number; retryAt: number; committed?: Reference; previewSubjectUris?: string[]; deviceCounter?: number; intentHash?: string };
export type OutboxState = { device?: V2DeviceState; publication?: V2PublicationCheckpoint; viewerDid: string; entries: OutboxEntry[]; lastError?: string; migration?: import("./migration").MigrationCheckpoint; verifiedAuthority?: import("./migration").ReadStateStatus };
export interface OutboxStore {
  read(viewer: string): Promise<OutboxState>;
  update(viewer: string, update: (state: OutboxState) => OutboxState): Promise<OutboxState>;
}
export class PDSRequestError extends Error {
  constructor(public readonly status: number, public readonly retryAfter?: string,
    public readonly rateLimitReset?: string, public readonly code?: string) { super(`PDS request failed (${status})`); }
}
export function retryDelay(error: unknown, attempts: number, now: number, jitter: number): number {
  if (error instanceof PDSRequestError) {
    const seconds = Number(error.retryAfter);
    const retryAt = error.retryAfter
      ? (Number.isFinite(seconds) ? now + Math.max(0, seconds) * 1000 : Date.parse(error.retryAfter)) : 0;
    const reset = Number(error.rateLimitReset) * 1000;
    if (retryAt > now || reset > now) return Math.max(retryAt || 0, reset || 0) - now;
  }
  return Math.min(3_600_000, 1000 * 2 ** Math.min(12, attempts)) * (1 + Math.max(0, Math.min(1, jitter)) / 4);
}
function sameSelection(first: Intent, second: Intent): boolean {
  if (first.selection !== second.selection || first.calendar || second.calendar) return false;
  return JSON.stringify(first.selection === "exact" ? [...first.subjectUris].sort() : first.boundaries)
    === JSON.stringify(second.selection === "exact" ? [...second.subjectUris].sort() : second.boundaries);
}
export class ReadStateOutbox {
  constructor(private readonly store: OutboxStore, private readonly repository: ReadStateRepository,
    private readonly confirm: (reference: Reference) => Promise<void>,
    private readonly withLock: <T>(key: string, operation: () => Promise<T>) => Promise<T>,
    private readonly now: () => number = Date.now, private readonly random: () => number = Math.random) {}

  snapshot(): Promise<OutboxState> { return this.store.read(this.repository.viewerDid); }

  async enqueue(intent: Intent, previewSubjectUris?: string[]): Promise<void> {
    validateIntent(intent);
    if (previewSubjectUris && (intent.selection !== "boundaries" || previewSubjectUris.length > 1000
      || previewSubjectUris.some(uri => typeof uri !== "string" || !uri || new TextEncoder().encode(uri).length > 2048)))
      throw new ReadStateError("invalid_record");
    await this.store.update(this.repository.viewerDid, state => {
        if (state.entries.some(entry => entry.intent.actionId === intent.actionId)) return state;
        const entries = [...state.entries]; const last = entries.at(-1);
        // Only consecutive unpublished identical selections may replace earlier intent.
        // Once attempted, its public commit outcome may be uncertain, so never coalesce it away.
        if (last && last.attempts === 0 && !last.committed
          && sameSelection(last.intent, intent)) entries.pop();
        entries.push({ intent, attempts: 0, retryAt: 0, ...(previewSubjectUris ? { previewSubjectUris: [...new Set(previewSubjectUris)] } : {}) });
        return { ...state, entries };
    });
  }

  async flushOnce(): Promise<boolean> {
    return this.withLock(this.repository.viewerDid, async () => {
      let batch: OutboxEntry[] = [];
      await this.store.update(this.repository.viewerDid, current => {
        const first = current.entries[0];
        if (!first || first.retryAt > this.now()) return current;
        batch = current.entries.slice(0, 32);
        const selected = new Set(batch.map(item => item.intent.actionId));
        return { ...current, entries: current.entries.map(item => selected.has(item.intent.actionId)
          ? { ...item, attempts: item.attempts + 1 } : item) };
      });
      const entry = batch[0]; if (!entry) return false;
      const ids = new Set(batch.map(item => item.intent.actionId));
      try {
        // Always reload/merge after retries. A newer manifest can contain this already committed action.
        const reference = await commitIntents(this.repository, batch.map(item => item.intent), { requireExistingManifest: true });
        await this.store.update(this.repository.viewerDid, current => ({ ...current,
          entries: current.entries.map(item => ids.has(item.intent.actionId) ? { ...item, committed: reference } : item) }));
        await this.confirm(reference);
        await this.store.update(this.repository.viewerDid, current => ({ ...current, lastError: undefined,
          entries: current.entries.filter(item => !ids.has(item.intent.actionId)) }));
        return true;
      } catch (error) {
        const reason = error instanceof ReadStateError ? error.code
          : error instanceof PDSRequestError && (error.status === 401 || error.status === 403) ? "reauthorize" : "unavailable";
        const retryAt = this.now() + (reason === "reauthorize" ? 60_000
          : retryDelay(error, entry.attempts, this.now(), this.random()));
        await this.store.update(this.repository.viewerDid, current => ({ ...current, lastError: reason,
          entries: current.entries.map(item => ids.has(item.intent.actionId) ? { ...item, retryAt } : item) }));
        return false;
      }
    });
  }
}
