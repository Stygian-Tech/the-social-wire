export const MANIFEST_COLLECTION = "app.thesocialwire.readState";
export const CHUNK_COLLECTION = "app.thesocialwire.readStateChunk";
export const MAX_RECORD_BYTES = 65_536;
export type Reference = { uri: string; cid: string };
export type Scope = { publicationId: string; authorDid: string; publicationSiteKeys: string[] };
export type Boundary = { scope: Scope; createdAt: string; entryId?: string };
export type CalendarSelection = { cutoff: string; timeZone: string; referenceDate: string };
export type Intent = {
  actionId: string;
  state: "read" | "unread";
  actedAt: string;
  calendar?: CalendarSelection;
} & ({ selection: "exact"; subjectUris: string[]; boundaries?: never }
  | { selection: "boundaries"; boundaries: Boundary[]; subjectUris?: never });
export type Operation = Intent & { sequence: number };
export type Chunk = { $type: typeof CHUNK_COLLECTION; version: 1; operations: Operation[]; previous?: Reference };
export type Manifest = {
  $type: typeof MANIFEST_COLLECTION; version: 1; generation: string; lastSequence: number; head?: Reference;
};
export type Subject = { uri: string; authorDid: string; publicationSite?: string; createdAt: string };
export type Resolution = { isRead: boolean; sequence: number; actionId?: string; readAt?: string };
export class ReadStateError extends Error {
  constructor(public readonly code: "invalid_record" | "invalid_reference" | "size_limit" | "incomplete_generation"
    | "migration_scope_conflict" | "projection_not_ready" | "conflicting_sequence" | "invalid_cid" | "conflict" | "unavailable" | "reauthorize" | "outbox_unavailable",
  message: string = code) { super(message); this.name = "ReadStateError"; }
}
