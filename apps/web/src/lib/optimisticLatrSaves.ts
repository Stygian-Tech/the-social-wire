import {
  COLLECTION_LATR_SAVED_EXTERNAL,
  COLLECTION_LATR_SAVED_ITEM,
} from "@/lib/latrCollections";
import {
  latrExternalRkeyFromNormalizedUrl,
  latrItemRkeyFromSubjectUri,
  normalizeLatrHttpsUrl,
} from "@/lib/latrSavedUrls";
import type { MergedLatrSave } from "@/lib/pdsClient";

export type LatrSaveCacheSnapshot = {
  previousActive?: MergedLatrSave[];
  previousArchived?: MergedLatrSave[];
};

function sortLatrSavesBySavedAt(rows: MergedLatrSave[]): MergedLatrSave[] {
  return [...rows].sort((a, b) => {
    const ta = Date.parse(a.savedAt);
    const tb = Date.parse(b.savedAt);
    return (Number.isNaN(tb) ? 0 : tb) - (Number.isNaN(ta) ? 0 : ta);
  });
}

export function findLatrSaveByItemRkey(
  rows: MergedLatrSave[] | undefined,
  itemRkey: string
): MergedLatrSave | undefined {
  return rows?.find((row) => row.itemRkey === itemRkey);
}

export function removeLatrSaveByItemRkey(
  rows: MergedLatrSave[] | undefined,
  itemRkey: string
): MergedLatrSave[] {
  if (!rows?.length) return [];
  return rows.filter((row) => row.itemRkey !== itemRkey);
}

export function upsertLatrSaveRow(
  rows: MergedLatrSave[] | undefined,
  row: MergedLatrSave
): MergedLatrSave[] {
  const without = removeLatrSaveByItemRkey(rows, row.itemRkey);
  return sortLatrSavesBySavedAt([row, ...without]);
}

export function applyLatrSaveDelete(
  active: MergedLatrSave[] | undefined,
  archived: MergedLatrSave[] | undefined,
  itemRkey: string
): { active: MergedLatrSave[]; archived: MergedLatrSave[] } {
  return {
    active: removeLatrSaveByItemRkey(active, itemRkey),
    archived: removeLatrSaveByItemRkey(archived, itemRkey),
  };
}

export function applyLatrSaveArchive(
  active: MergedLatrSave[] | undefined,
  archived: MergedLatrSave[] | undefined,
  itemRkey: string
): { active: MergedLatrSave[]; archived: MergedLatrSave[] } | null {
  const row = findLatrSaveByItemRkey(active, itemRkey);
  if (!row) return null;

  const archivedRow: MergedLatrSave = { ...row, state: "archived" };
  return {
    active: removeLatrSaveByItemRkey(active, itemRkey),
    archived: upsertLatrSaveRow(archived, archivedRow),
  };
}

export function applyLatrSaveUnarchive(
  active: MergedLatrSave[] | undefined,
  archived: MergedLatrSave[] | undefined,
  itemRkey: string
): { active: MergedLatrSave[]; archived: MergedLatrSave[] } | null {
  const row = findLatrSaveByItemRkey(archived, itemRkey);
  if (!row) return null;

  const activeRow: MergedLatrSave = { ...row, state: "unread" };
  return {
    active: upsertLatrSaveRow(active, activeRow),
    archived: removeLatrSaveByItemRkey(archived, itemRkey),
  };
}

export async function buildOptimisticExternalLatrSave(
  viewerDid: string,
  url: string,
  options?: { title?: string; excerpt?: string }
): Promise<MergedLatrSave> {
  const normalizedUrl = normalizeLatrHttpsUrl(url);
  if (!normalizedUrl) {
    throw new Error("Cannot optimistically save — invalid URL");
  }

  const externalRkey = await latrExternalRkeyFromNormalizedUrl(normalizedUrl);
  const externalUri = `at://${viewerDid}/${COLLECTION_LATR_SAVED_EXTERNAL}/${externalRkey}`;
  const itemRkey = await latrItemRkeyFromSubjectUri(externalUri);
  const itemUri = `at://${viewerDid}/${COLLECTION_LATR_SAVED_ITEM}/${itemRkey}`;

  return {
    kind: "external",
    normalizedUrl,
    url: normalizedUrl,
    savedAt: new Date().toISOString(),
    externalRkey,
    itemRkey,
    externalUri,
    itemUri,
    subjectUri: externalUri,
    state: "unread",
    ...(options?.title?.trim() ? { title: options.title.trim() } : {}),
    ...(options?.excerpt?.trim() ? { excerpt: options.excerpt.trim() } : {}),
  };
}

export async function buildOptimisticNativeLatrSave(
  viewerDid: string,
  subjectUri: string,
  options?: {
    title?: string;
    excerpt?: string;
    url?: string;
    linkedWebUrl?: string;
  }
): Promise<MergedLatrSave> {
  const itemRkey = await latrItemRkeyFromSubjectUri(subjectUri);
  const itemUri = `at://${viewerDid}/${COLLECTION_LATR_SAVED_ITEM}/${itemRkey}`;

  return {
    kind: "native",
    savedAt: new Date().toISOString(),
    itemRkey,
    itemUri,
    subjectUri,
    state: "unread",
    ...(options?.title?.trim() ? { title: options.title.trim() } : {}),
    ...(options?.excerpt?.trim() ? { excerpt: options.excerpt.trim() } : {}),
    ...(options?.url?.trim() ? { url: options.url.trim() } : {}),
    ...(options?.linkedWebUrl?.trim()
      ? { linkedWebUrl: options.linkedWebUrl.trim() }
      : {}),
  };
}
