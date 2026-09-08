import type { Operation, Reference } from "./types";
import type { DeviceReceipt, LegacyActionReceipt } from "./v2Foundation";

export type V2Manifest = {
  $type: "app.thesocialwire.readState"; version: 2; generation: string; revision: number;
  lastSequence: number; compactionVersion: 1; stateHead?: Reference; devicesHead?: Reference;
  legacyReceiptsHead?: Reference;
};
/** A surviving subset of an original intent, whose retry identity is kept separately. */
export type V2Fragment = Operation & { fragment: true; intentHash: string; deviceId?: string; deviceCounter?: number };
export type V2Chunk = { $type: "app.thesocialwire.readStateChunk"; version: 2; previous?: Reference } & (
  { kind: "state"; fragments: V2Fragment[] } | { kind: "devices"; receipts: DeviceReceipt[] }
  | { kind: "legacyReceipts"; receipts: LegacyActionReceipt[] });
export type V2DeviceState = { deviceId: string; nextCounter: number; acknowledgedCounter: number; acknowledgedPrefixHash: string };
export type V2PublicationCheckpoint = { baseCid: string; revision: number; uploaded: Reference[] };
