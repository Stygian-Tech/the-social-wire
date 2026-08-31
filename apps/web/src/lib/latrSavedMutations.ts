import type { QueryClient } from "@tanstack/react-query";

import {
  applyLatrSaveArchive,
  applyLatrSaveDelete,
  applyLatrSaveUnarchive,
  type LatrSaveCacheSnapshot,
  upsertLatrSaveRow,
} from "@/lib/optimisticLatrSaves";
import type { MergedLatrSave } from "@/lib/pdsClient";
import { readLaterQueryKeys } from "@/lib/semble";

export const LATR_SAVED_QUERY_KEY = ["latrSavedHttps"] as const;
export const LATR_ARCHIVED_QUERY_KEY = ["latrArchivedHttps"] as const;

export type LatrSaveQueryKeys = {
  active: readonly unknown[];
  archived: readonly unknown[];
};

export const LEGACY_LATR_SAVE_QUERY_KEYS: LatrSaveQueryKeys = {
  active: LATR_SAVED_QUERY_KEY,
  archived: LATR_ARCHIVED_QUERY_KEY,
};

export function scopedLatrSaveQueryKeys(viewerDid: string): LatrSaveQueryKeys {
  const base = readLaterQueryKeys.items(viewerDid, "latr-gateway", "default");
  return {
    active: [...base, "active"] as const,
    archived: [...base, "archived"] as const,
  };
}

export function invalidateLatrSaveQueries(
  qc: QueryClient,
  keys: LatrSaveQueryKeys = LEGACY_LATR_SAVE_QUERY_KEYS,
): void {
  void qc.invalidateQueries({ queryKey: keys.active });
  void qc.invalidateQueries({ queryKey: keys.archived });
}

export async function snapshotLatrSaveQueries(
  qc: QueryClient,
  keys: LatrSaveQueryKeys = LEGACY_LATR_SAVE_QUERY_KEYS,
): Promise<LatrSaveCacheSnapshot> {
  await qc.cancelQueries({ queryKey: keys.active });
  await qc.cancelQueries({ queryKey: keys.archived });
  return {
    previousActive: qc.getQueryData<MergedLatrSave[]>(keys.active),
    previousArchived: qc.getQueryData<MergedLatrSave[]>(keys.archived),
  };
}

export function restoreLatrSaveQueries(
  qc: QueryClient,
  snapshot: LatrSaveCacheSnapshot | undefined,
  keys: LatrSaveQueryKeys = LEGACY_LATR_SAVE_QUERY_KEYS,
): void {
  if (!snapshot) return;
  if (snapshot.previousActive !== undefined) {
    qc.setQueryData(keys.active, snapshot.previousActive);
  }
  if (snapshot.previousArchived !== undefined) {
    qc.setQueryData(keys.archived, snapshot.previousArchived);
  }
}

export function applyOptimisticLatrSaveDelete(
  qc: QueryClient,
  itemRkey: string,
  keys: LatrSaveQueryKeys = LEGACY_LATR_SAVE_QUERY_KEYS,
): void {
  const active = qc.getQueryData<MergedLatrSave[]>(keys.active);
  const archived = qc.getQueryData<MergedLatrSave[]>(keys.archived);
  const next = applyLatrSaveDelete(active, archived, itemRkey);
  qc.setQueryData(keys.active, next.active);
  qc.setQueryData(keys.archived, next.archived);
}

export function applyOptimisticLatrSaveArchive(
  qc: QueryClient,
  itemRkey: string,
  keys: LatrSaveQueryKeys = LEGACY_LATR_SAVE_QUERY_KEYS,
): void {
  const active = qc.getQueryData<MergedLatrSave[]>(keys.active);
  const archived = qc.getQueryData<MergedLatrSave[]>(keys.archived);
  const next = applyLatrSaveArchive(active, archived, itemRkey);
  if (!next) return;
  qc.setQueryData(keys.active, next.active);
  qc.setQueryData(keys.archived, next.archived);
}

export function applyOptimisticLatrSaveUnarchive(
  qc: QueryClient,
  itemRkey: string,
  keys: LatrSaveQueryKeys = LEGACY_LATR_SAVE_QUERY_KEYS,
): void {
  const active = qc.getQueryData<MergedLatrSave[]>(keys.active);
  const archived = qc.getQueryData<MergedLatrSave[]>(keys.archived);
  const next = applyLatrSaveUnarchive(active, archived, itemRkey);
  if (!next) return;
  qc.setQueryData(keys.active, next.active);
  qc.setQueryData(keys.archived, next.archived);
}

export function applyOptimisticLatrSaveInsert(
  qc: QueryClient,
  row: MergedLatrSave,
  keys: LatrSaveQueryKeys = LEGACY_LATR_SAVE_QUERY_KEYS,
): void {
  const active = qc.getQueryData<MergedLatrSave[]>(keys.active);
  qc.setQueryData(keys.active, upsertLatrSaveRow(active, row));
}

export function applyOptimisticLatrSaveTags(
  qc: QueryClient,
  bookmarkUri: string,
  tags: string[],
  keys: LatrSaveQueryKeys = LEGACY_LATR_SAVE_QUERY_KEYS,
): void {
  for (const key of [keys.active, keys.archived]) {
    qc.setQueryData<MergedLatrSave[]>(key, (rows) =>
      rows?.map((row) =>
        row.itemRkey === bookmarkUri ? { ...row, tags: [...tags] } : row
      )
    );
  }
}
