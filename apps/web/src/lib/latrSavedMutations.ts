import type { QueryClient } from "@tanstack/react-query";

import {
  applyLatrSaveArchive,
  applyLatrSaveDelete,
  applyLatrSaveUnarchive,
  type LatrSaveCacheSnapshot,
  upsertLatrSaveRow,
} from "@/lib/optimisticLatrSaves";
import type { MergedLatrSave } from "@/lib/pdsClient";

export const LATR_SAVED_QUERY_KEY = ["latrSavedHttps"] as const;
export const LATR_ARCHIVED_QUERY_KEY = ["latrArchivedHttps"] as const;

export function invalidateLatrSaveQueries(qc: QueryClient): void {
  void qc.invalidateQueries({ queryKey: LATR_SAVED_QUERY_KEY });
  void qc.invalidateQueries({ queryKey: LATR_ARCHIVED_QUERY_KEY });
}

export async function snapshotLatrSaveQueries(
  qc: QueryClient
): Promise<LatrSaveCacheSnapshot> {
  await qc.cancelQueries({ queryKey: LATR_SAVED_QUERY_KEY });
  await qc.cancelQueries({ queryKey: LATR_ARCHIVED_QUERY_KEY });
  return {
    previousActive: qc.getQueryData<MergedLatrSave[]>(LATR_SAVED_QUERY_KEY),
    previousArchived: qc.getQueryData<MergedLatrSave[]>(LATR_ARCHIVED_QUERY_KEY),
  };
}

export function restoreLatrSaveQueries(
  qc: QueryClient,
  snapshot: LatrSaveCacheSnapshot | undefined
): void {
  if (!snapshot) return;
  if (snapshot.previousActive !== undefined) {
    qc.setQueryData(LATR_SAVED_QUERY_KEY, snapshot.previousActive);
  }
  if (snapshot.previousArchived !== undefined) {
    qc.setQueryData(LATR_ARCHIVED_QUERY_KEY, snapshot.previousArchived);
  }
}

export function applyOptimisticLatrSaveDelete(
  qc: QueryClient,
  itemRkey: string
): void {
  const active = qc.getQueryData<MergedLatrSave[]>(LATR_SAVED_QUERY_KEY);
  const archived = qc.getQueryData<MergedLatrSave[]>(LATR_ARCHIVED_QUERY_KEY);
  const next = applyLatrSaveDelete(active, archived, itemRkey);
  qc.setQueryData(LATR_SAVED_QUERY_KEY, next.active);
  qc.setQueryData(LATR_ARCHIVED_QUERY_KEY, next.archived);
}

export function applyOptimisticLatrSaveArchive(
  qc: QueryClient,
  itemRkey: string
): void {
  const active = qc.getQueryData<MergedLatrSave[]>(LATR_SAVED_QUERY_KEY);
  const archived = qc.getQueryData<MergedLatrSave[]>(LATR_ARCHIVED_QUERY_KEY);
  const next = applyLatrSaveArchive(active, archived, itemRkey);
  if (!next) return;
  qc.setQueryData(LATR_SAVED_QUERY_KEY, next.active);
  qc.setQueryData(LATR_ARCHIVED_QUERY_KEY, next.archived);
}

export function applyOptimisticLatrSaveUnarchive(
  qc: QueryClient,
  itemRkey: string
): void {
  const active = qc.getQueryData<MergedLatrSave[]>(LATR_SAVED_QUERY_KEY);
  const archived = qc.getQueryData<MergedLatrSave[]>(LATR_ARCHIVED_QUERY_KEY);
  const next = applyLatrSaveUnarchive(active, archived, itemRkey);
  if (!next) return;
  qc.setQueryData(LATR_SAVED_QUERY_KEY, next.active);
  qc.setQueryData(LATR_ARCHIVED_QUERY_KEY, next.archived);
}

export function applyOptimisticLatrSaveInsert(
  qc: QueryClient,
  row: MergedLatrSave
): void {
  const active = qc.getQueryData<MergedLatrSave[]>(LATR_SAVED_QUERY_KEY);
  qc.setQueryData(LATR_SAVED_QUERY_KEY, upsertLatrSaveRow(active, row));
}
