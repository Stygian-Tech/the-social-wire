import { loadGeneration, publishMigration, type ReadStateRepository } from "./repository";
import { ReadStateError, type Boundary, type Intent, type Manifest, type Reference } from "./types";
import { jsonBytes } from "./validation";

export type ReadStateStatus = { authority: "appview" | "pds"; migrationState: "notStarted" | "verified";
  legacyRevision: number; manifest?: Manifest; manifestCid?: string };
export type LegacyRow = { kind: "boundary" | "unread" | "read"; actedAt: string; boundary?: Boundary; subjectUri?: string };
export type MigrationExportPage = { legacyRevision: number; rows: LegacyRow[]; cursor?: string };
export type MigrationCheckpoint = { id: string; viewerDid: string; expectedManifestCid: string | null;
  legacyRevision?: number; rows: LegacyRow[]; cursor?: string; exportComplete: boolean; committed?: Reference };
export interface MigrationCheckpointStore {
  read(viewer: string): Promise<MigrationCheckpoint | null>;
  write(viewer: string, checkpoint: MigrationCheckpoint | null): Promise<void>;
}
export interface ReadStateMigrationGateway {
  status(): Promise<ReadStateStatus>;
  exportPage(cursor?: string, expectedLegacyRevision?: number): Promise<MigrationExportPage>;
  confirm(reference: Reference, expectedLegacyRevision?: number): Promise<ReadStateStatus>;
}
export function migrationIntents(checkpoint: MigrationCheckpoint): Intent[] {
  let lastKind = 0;
  return checkpoint.rows.map((row, index): Intent => {
    const kind = { boundary: 0, unread: 1, read: 2 }[row.kind];
    if (kind === undefined || kind < lastKind) throw new ReadStateError("invalid_record");
    lastKind = kind;
    const common = { actionId: `${checkpoint.id}-${index}`, actedAt: row.actedAt, state: row.kind === "unread" ? "unread" as const : "read" as const };
    if (row.kind === "boundary" && row.boundary && row.subjectUri === undefined)
      return { ...common, selection: "boundaries", boundaries: [row.boundary] };
    if (row.kind !== "boundary" && row.subjectUri && row.boundary === undefined)
      return { ...common, selection: "exact", subjectUris: [row.subjectUri] };
    throw new ReadStateError("invalid_record");
  });
}
/** One resumable migration step. No client flag grants PDS authority. */
export async function migrateReadState(repository: ReadStateRepository, gateway: ReadStateMigrationGateway,
  store: MigrationCheckpointStore): Promise<ReadStateStatus> {
  const status = await gateway.status();
  if (status.authority === "pds") { await store.write(repository.viewerDid, null); return status; }
  let checkpoint = await store.read(repository.viewerDid);
  if (!checkpoint || (checkpoint.legacyRevision !== undefined && checkpoint.legacyRevision !== status.legacyRevision)) {
    const generation = await loadGeneration(repository);
    checkpoint = { id: crypto.randomUUID(), viewerDid: repository.viewerDid,
      expectedManifestCid: generation.record?.cid ?? null, rows: [], exportComplete: false };
    await store.write(repository.viewerDid, checkpoint);
  }
  if (checkpoint.viewerDid !== repository.viewerDid) throw new ReadStateError("invalid_record");
  const seenCursors = new Set<string>();
  while (!checkpoint.exportComplete) {
    if (checkpoint.cursor && seenCursors.has(checkpoint.cursor)) throw new ReadStateError("incomplete_generation");
    if (checkpoint.cursor) seenCursors.add(checkpoint.cursor);
    const page = await gateway.exportPage(checkpoint.cursor, checkpoint.legacyRevision);
    if (!Number.isSafeInteger(page.legacyRevision) || page.legacyRevision < 0
      || (checkpoint.legacyRevision !== undefined && checkpoint.legacyRevision !== page.legacyRevision))
      throw new ReadStateError("conflict");
    const rows: LegacyRow[] = [...checkpoint.rows, ...page.rows];
    if (jsonBytes(rows) > 12 * 1024 * 1024) throw new ReadStateError("size_limit");
    checkpoint = { ...checkpoint, rows, legacyRevision: page.legacyRevision,
      cursor: page.cursor, exportComplete: !page.cursor };
    await store.write(repository.viewerDid, checkpoint);
  }
  const intents = migrationIntents(checkpoint);
  let committed: Reference;
  try { committed = await publishMigration(repository, checkpoint.id, intents, checkpoint.expectedManifestCid); }
  catch (error) {
    if (error instanceof ReadStateError && error.code === "conflict") {
      // Another migration may have activated while this baseline uploaded. Never overwrite it.
      const latestStatus = await gateway.status();
      if (latestStatus.authority === "pds") { await store.write(repository.viewerDid, null); return latestStatus; }
      // Still legacy-authoritative: a complete re-export may replace the unactivated candidate by CAS.
      await store.write(repository.viewerDid, null);
    }
    throw error;
  }
  checkpoint = { ...checkpoint, committed };
  await store.write(repository.viewerDid, checkpoint);
  const confirmed = await gateway.confirm(committed, checkpoint.legacyRevision);
  if (confirmed.authority !== "pds" || confirmed.migrationState !== "verified") throw new ReadStateError("incomplete_generation");
  await store.write(repository.viewerDid, null);
  return confirmed;
}
