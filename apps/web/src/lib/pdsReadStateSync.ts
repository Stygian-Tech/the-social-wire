import type { OAuthSession } from "@atproto/oauth-client-browser";
import { IndexedDBReadStateOutbox, ReadStateError, V2ReadStateOutbox, browserReadStateLock, migrateReadState,
  MANIFEST_COLLECTION, recordCID, validateManifest, validateV2Manifest, type Intent, type MigrationCheckpointStore, type OutboxState, type ReadStateStatus } from "@thesocialwire/read-state";
import { OAuthReadStateRepository } from "./pdsReadStateRepository";
import { PDSReadStateGateway } from "./pdsReadStateGateway";
import type { GatewayMarkAllReadScope } from "./publicationProjectionClient";

export const PDS_READ_HISTORY_NOTICE = "Read and unread history is public on your PDS. Pending changes remain on this device until synchronization completes.";
export const pdsReadStateEnabled = () => process.env.NEXT_PUBLIC_PDS_READ_STATE_ENABLED === "true";
export const PDS_READ_STATE_SYNC_EVENT = "socialwire:pds-read-state-sync";
const runtimes = new WeakMap<OAuthSession, PDSReadStateSync>();

export class PDSReadStateSync {
  private active = true;
  private consumers = 0;
  localError?: string;
  private readonly store = new IndexedDBReadStateOutbox();
  private readonly repository: OAuthReadStateRepository;
  readonly gateway: PDSReadStateGateway;
  private readonly outbox: V2ReadStateOutbox;
  private readonly migrationStore: MigrationCheckpointStore;
  private statusValue?: ReadStateStatus;
  private timer?: ReturnType<typeof setInterval>;
  constructor(private readonly oauth: OAuthSession) {
    const assertCurrent = () => { if (!this.active) throw new ReadStateError("reauthorize"); };
    this.repository = new OAuthReadStateRepository(oauth, assertCurrent);
    this.gateway = new PDSReadStateGateway(oauth, assertCurrent);
    this.outbox = new V2ReadStateOutbox(this.store, this.repository, async reference => {
      const status = await this.gateway.confirm(reference);
      if (status.authority !== "pds" || status.migrationState !== "verified") throw new ReadStateError("incomplete_generation");
      this.statusValue = status;
      await this.rememberAuthority(status);
    }, browserReadStateLock);
    this.migrationStore = {
      read: async viewer => (await this.store.read(viewer)).migration ?? null,
      write: async (viewer, checkpoint) => { await this.store.update(viewer, state => ({ ...state, migration: checkpoint ?? undefined })); },
    };
  }
  retain(): () => void {
    this.active = true; this.consumers++;
    return () => { if (--this.consumers === 0) this.stop(); };
  }
  stop() { this.active = false; if (this.timer) clearInterval(this.timer); this.timer = undefined; }
  private async rememberAuthority(status: ReadStateStatus): Promise<void> {
    if (status.authority === "pds" && status.migrationState === "verified")
      await this.store.update(this.oauth.did, state => ({ ...state, verifiedAuthority: status }));
  }
  async status(force = false): Promise<ReadStateStatus> {
    if (!this.statusValue && !force) this.statusValue = (await this.store.read(this.oauth.did)).verifiedAuthority;
    // Once verified, authority is monotonic. Keep the server receipt for offline enqueue;
    // bootstrap rechecks the server. This local receipt never grants server authority.
    if (this.statusValue?.authority === "pds" && !force) return this.statusValue;
    this.statusValue = await this.gateway.status();
    await this.rememberAuthority(this.statusValue);
    return this.statusValue;
  }
  snapshot(): Promise<OutboxState> { return this.outbox.snapshot(); }
  async bootstrap(): Promise<void> {
    if (!this.timer) this.timer = setInterval(() => { void this.flush().catch(() => {}); }, 1000);
    const status = await this.status(true);
    if (status.authority === "pds") {
      const current = await this.repository.getRecord(MANIFEST_COLLECTION, "self");
      if (!current) throw new ReadStateError("incomplete_generation");
      if ((current.value as { version?: number }).version === 2) validateV2Manifest(current.value, this.oauth.did);
      else validateManifest(current.value, this.oauth.did);
      if (current.cid !== await recordCID(current.value)) throw new ReadStateError("invalid_cid");
      if (current.cid !== status.manifestCid) this.statusValue = await this.gateway.confirm(current);
      this.changed("confirmed");
    }
    await this.flush();
  }
  async flush(): Promise<void> {
    if (!this.active || this.statusValue?.authority !== "pds" || (typeof navigator !== "undefined" && !navigator.onLine)) return;
    const exported = await this.outbox.flushOnce();
    const pending = await this.outbox.snapshot();
    if (exported || pending.lastError) this.changed(exported ? "confirmed" : "error");
  }
  async migrate(): Promise<ReadStateStatus> {
    // Uses the same cross-tab/account lock as normal writes; a partial migration never grants authority.
    const status = await browserReadStateLock(this.oauth.did, () => migrateReadState(this.repository, this.gateway, this.migrationStore));
    this.statusValue = status; await this.rememberAuthority(status); this.changed(); return status;
  }
  async enqueue(intent: Intent, previewSubjectUris?: string[]): Promise<void> {
    try {
      if ((await this.status()).authority !== "pds") throw new ReadStateError("incomplete_generation");
      await this.outbox.enqueue(intent, previewSubjectUris); this.localError = undefined; this.changed("queued"); }
    catch (error) { this.localError = "Changes could not be saved on this device. Try again before closing this page."; this.changed("error"); throw error; }
  }
  async exact(subjectUris: string[], state: "read" | "unread", actedAt = new Date().toISOString()): Promise<void> {
    await this.enqueue({ actionId: crypto.randomUUID(), state, actedAt, selection: "exact", subjectUris: [...new Set(subjectUris)] });
  }
  async bulk(scope: GatewayMarkAllReadScope, calendar?: { before: string; timeZone: string; referenceDate: string }, previewSubjectUris?: string[]) {
    const prepared = await this.gateway.prepare(scope, calendar, previewSubjectUris);
    if ((prepared.selection === "exact" ? prepared.subjectUris.length : prepared.boundaries.length) > 0) {
      const common = { actionId: crypto.randomUUID(), state: "read" as const, actedAt: prepared.actedAt };
      await this.enqueue(prepared.selection === "exact"
        ? { ...common, selection: "exact", subjectUris: prepared.subjectUris, ...(prepared.calendar ? { calendar: prepared.calendar } : {}) }
        : { ...common, selection: "boundaries", boundaries: prepared.boundaries },
        prepared.selection === "boundaries" ? prepared.previewSubjectUris : undefined);
    }
    return prepared;
  }
  private changed(kind: "queued" | "confirmed" | "error" = "confirmed") {
    if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent(PDS_READ_STATE_SYNC_EVENT, { detail: { viewerDid: this.oauth.did, kind } }));
  }
}
export function pdsReadStateSync(oauth: OAuthSession): PDSReadStateSync {
  let runtime = runtimes.get(oauth);
  if (!runtime) { runtime = new PDSReadStateSync(oauth); runtimes.set(oauth, runtime); }
  return runtime;
}
/** A migrated account fails closed if status is unavailable: never silently fall back to legacy writes. */
export async function usesPDSReadState(oauth: OAuthSession, force = false): Promise<boolean> {
  return pdsReadStateEnabled() && (await pdsReadStateSync(oauth).status(force)).authority === "pds";
}
