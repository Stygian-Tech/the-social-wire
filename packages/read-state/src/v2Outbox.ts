import { ReadStateError, type Intent, type Reference } from "./types";
import { PDSRequestError, retryDelay, type OutboxEntry, type OutboxState, type OutboxStore } from "./outbox";
import { packIntent, type ReadStateRepository } from "./repository";
import { initialDeviceReceipt, originalIntentHash, verifyDeviceAcknowledgement, advanceDeviceReceipt, type DeviceReceipt } from "./v2Foundation";
import { ensureV2Generation, publishV2Intents } from "./v2Repository";
import { hashValue, safeCounter, deviceIdValue } from "./v2Validation";
import { validateIntent } from "./validation";
import type { V2DeviceState } from "./v2Types";

function receipt(device: V2DeviceState): DeviceReceipt {
  return { deviceId: device.deviceId, committedCounter: device.acknowledgedCounter, prefixHash: device.acknowledgedPrefixHash };
}
function checkQueue(state: OutboxState): asserts state is OutboxState & { device: V2DeviceState } {
  const device = state.device;
  if (!device || !deviceIdValue(device.deviceId) || !safeCounter(device.acknowledgedCounter) || !safeCounter(device.nextCounter)
    || device.nextCounter !== device.acknowledgedCounter + state.entries.length + 1 || !hashValue(device.acknowledgedPrefixHash)
    || state.entries.some((entry, index) => entry.deviceCounter !== device.acknowledgedCounter + index + 1 || !hashValue(entry.intentHash)))
    throw new ReadStateError("conflicting_sequence", "Device retry history conflicts. Pending changes remain protected.");
}
function sameSelection(first: Intent, second: Intent): boolean {
  if (first.selection !== second.selection || first.calendar || second.calendar) return false;
  return JSON.stringify(first.selection === "exact" ? [...first.subjectUris].sort() : first.boundaries)
    === JSON.stringify(second.selection === "exact" ? [...second.subjectUris].sort() : second.boundaries);
}
/** FIFO device receipts survive semantic pruning and unknown-success retries. */
export class V2ReadStateOutbox {
  constructor(private readonly store: OutboxStore, private readonly repository: ReadStateRepository,
    private readonly confirm: (reference: Reference) => Promise<void>,
    private readonly withLock: <T>(key: string, operation: () => Promise<T>) => Promise<T>,
    private readonly now: () => number = Date.now, private readonly random: () => number = Math.random) {}

  snapshot(): Promise<OutboxState> { return this.store.read(this.repository.viewerDid); }

  private async assignLegacyQueue(): Promise<void> {
    for (let attempt = 0; attempt < 8; attempt++) {
      const snapshot = await this.snapshot();
      if (snapshot.device && snapshot.entries.every(entry => entry.deviceCounter !== undefined)) { checkQueue(snapshot); return; }
      const initial = await initialDeviceReceipt(this.repository.viewerDid, crypto.randomUUID());
      const hashes = new Map<string, { intent: string; hash: string }>();
      for (const entry of snapshot.entries) hashes.set(entry.intent.actionId, { intent: JSON.stringify(entry.intent),
        hash: await originalIntentHash(packIntent(entry.intent, 1).flat()) });
      let retry = false;
      await this.store.update(this.repository.viewerDid, state => {
        if (state.entries.some(entry => !entry.intentHash && hashes.get(entry.intent.actionId)?.intent !== JSON.stringify(entry.intent))) { retry = true; return state; }
        const device = state.device ?? { deviceId: initial.deviceId, nextCounter: 1, acknowledgedCounter: 0, acknowledgedPrefixHash: initial.prefixHash };
        const entries = state.entries.map((entry, index) => ({ ...entry,
          deviceCounter: entry.deviceCounter ?? device.acknowledgedCounter + index + 1,
          intentHash: entry.intentHash ?? hashes.get(entry.intent.actionId)!.hash }));
        const next = { ...state, entries, device: { ...device, nextCounter: device.acknowledgedCounter + entries.length + 1 } };
        checkQueue(next); return next;
      });
      if (!retry) return;
    }
    throw new ReadStateError("outbox_unavailable");
  }
  async enqueue(intent: Intent, previewSubjectUris?: string[]): Promise<void> {
    validateIntent(intent);
    if (previewSubjectUris && (intent.selection !== "boundaries" || previewSubjectUris.length > 1000
      || previewSubjectUris.some(uri => !uri || typeof uri !== "string" || new TextEncoder().encode(uri).length > 2048))) throw new ReadStateError("invalid_record");
    const intentHash = await originalIntentHash(packIntent(intent, 1).flat());
    await this.assignLegacyQueue();
    await this.store.update(this.repository.viewerDid, state => {
      checkQueue(state);
      const existing = state.entries.find(entry => entry.intent.actionId === intent.actionId);
      if (existing) {
        if (existing.intentHash !== intentHash) throw new ReadStateError("conflicting_sequence");
        return state;
      }
      const entries = [...state.entries], last = entries.at(-1);
      const replace = last && last.attempts === 0 && !last.committed && sameSelection(last.intent, intent);
      const deviceCounter = replace ? last.deviceCounter! : state.device.nextCounter;
      if (replace) entries.pop();
      entries.push({ intent, attempts: 0, retryAt: 0, intentHash, deviceCounter,
        ...(previewSubjectUris ? { previewSubjectUris: [...new Set(previewSubjectUris)] } : {}) });
      const next = { ...state, entries, device: { ...state.device, nextCounter: replace ? state.device.nextCounter : state.device.nextCounter + 1 } };
      checkQueue(next); return next;
    });
  }
  private async acknowledge(before: OutboxState & { device: V2DeviceState }, count: number, acknowledged: DeviceReceipt): Promise<void> {
    await this.store.update(this.repository.viewerDid, current => {
      checkQueue(current);
      if (current.device.deviceId !== before.device.deviceId || current.device.acknowledgedCounter !== before.device.acknowledgedCounter
        || current.device.acknowledgedPrefixHash !== before.device.acknowledgedPrefixHash
        || before.entries.slice(0, count).some((entry, index) => current.entries[index]?.intentHash !== entry.intentHash
          || current.entries[index]?.deviceCounter !== entry.deviceCounter)) throw new ReadStateError("conflicting_sequence");
      const next = { ...current, entries: current.entries.slice(count), lastError: undefined, publication: undefined,
        device: { ...current.device, acknowledgedCounter: acknowledged.committedCounter, acknowledgedPrefixHash: acknowledged.prefixHash } };
      checkQueue(next); return next;
    });
  }
  async flushOnce(): Promise<boolean> {
    return this.withLock(this.repository.viewerDid, async () => {
      await this.assignLegacyQueue();
      let state = await this.snapshot(); checkQueue(state);
      if (!state.entries.length || state.entries[0].retryAt > this.now()) return false;
      let batch: OutboxEntry[] = [];
      let ids = new Set<string>();
      await this.store.update(this.repository.viewerDid, current => {
        checkQueue(current);
        if (!current.entries.length || current.entries[0].retryAt > this.now()) return current;
        batch = current.entries.slice(0, 32); ids = new Set(batch.map(entry => entry.intent.actionId));
        return { ...current, entries: current.entries.map(entry => ids.has(entry.intent.actionId)
          ? { ...entry, attempts: entry.attempts + 1 } : entry) };
      });
      if (!batch.length) return false;
      try {
        for (let attempt = 0; attempt < 4; attempt++) {
          state = await this.snapshot(); checkQueue(state);
          const generation = await ensureV2Generation(this.repository, this.confirm);
          const remote = generation.devices.find(value => value.deviceId === state.device!.deviceId)
            ?? await initialDeviceReceipt(this.repository.viewerDid, state.device.deviceId);
          const count = await verifyDeviceAcknowledgement(receipt(state.device), remote, state.entries.map(entry => entry.intentHash!));
          if (count) {
            await this.confirm(generation.record);
            await this.acknowledge(state, count, remote); return true;
          }
          const selected = state.entries.slice(0, 32);
          try {
            const reference = await publishV2Intents(this.repository, generation, selected.map(entry => ({ intent: entry.intent,
              deviceId: state.device!.deviceId, deviceCounter: entry.deviceCounter!, intentHash: entry.intentHash! })), remote,
              async publication => { await this.store.update(this.repository.viewerDid, current => ({ ...current, publication })); });
            await this.store.update(this.repository.viewerDid, current => ({ ...current,
              entries: current.entries.map(entry => ids.has(entry.intent.actionId) ? { ...entry, committed: reference } : entry) }));
            await this.confirm(reference);
            const acknowledged = await advanceDeviceReceipt(remote, remote.committedCounter + 1, selected.map(entry => entry.intentHash!));
            await this.acknowledge(state, selected.length, acknowledged); return true;
          } catch (error) { if (!(error instanceof ReadStateError && error.code === "conflict")) throw error; }
        }
        throw new ReadStateError("conflict");
      } catch (error) {
        const reason = error instanceof ReadStateError ? error.code
          : error instanceof PDSRequestError && [401, 403].includes(error.status) ? "reauthorize" : "unavailable";
        const retryAt = this.now() + (reason === "reauthorize" ? 60_000 : retryDelay(error, batch[0].attempts, this.now(), this.random()));
        await this.store.update(this.repository.viewerDid, current => ({ ...current, lastError: reason,
          entries: current.entries.map(entry => ids.has(entry.intent.actionId) ? { ...entry, retryAt } : entry) }));
        return false;
      }
    });
  }
}
